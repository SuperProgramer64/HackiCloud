/* SPDX-License-Identifier: MIT
 * usbmuxd_dev: the phone's end of the USB multiplexer, what AppleUSBDeviceMux is on an iPhone. The kernel's MTU3
 * driver (usb=2) presents the phone to the Mac as usbmuxd expects one and moves the bulk data through
 * /dev/hakios-usbmux; this program speaks the mux (usbmux_core.h) and joins each connection the Mac opens to the
 * local service on that port: lockdownd at 62078 (its Unix socket first), the services it starts on theirs.
 * Port 19800 is ours: the kernel's log, live, from where it begins (tools/duchamp_usbmux_log.py on the Mac).
 * Started from /redwood/etc/rc.jobs. It tells the kernel lockdownd's UDID first: the Mac files the device under the
 * USB serial number, and lockdownd answers with this one.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sockio.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/param.h>
/* libproc, not in the iOS SDK headers */
int proc_listallpids(void *buffer, int buffersize);
int proc_name(int pid, void *buffer, uint32_t buffersize);
#include <sys/time.h>
#include "usbmux_core.h"

#define LOG_PORT 19800
#define DIAG_PORT 19801     /* a report on lockdownd from inside the phone, then closed */
#define RUN_PORT 19802      /* one command line, a program of /redwood/bin only; its output, then closed */

static int usb = -1;
static int wake[2];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct usbmux mux;
static uint64_t write_errors, opened, refused, delivered_late, overflowed;

/* the host's bytes a local socket could not take yet (trial 165: a send that blocked under the lock stopped the mux) */
#define MAX_FD 1024
#define PENDING_MAX (4u << 20)
static uint8_t *pending[MAX_FD];
static size_t pending_length[MAX_FD];

static void say(const char *format, ...)
{
	char line[300];
	va_list ap;
	va_start(ap, format);
	vsnprintf(line, sizeof(line), format, ap);
	va_end(ap);
	sysctlbyname("kern.hakios.say", NULL, NULL, line, strlen(line));
}

static void poke(void)
{
	char c = 1;
	(void)!write(wake[1], &c, 1);
}

/* ---- the mux's ops (called with the lock held) ---- */

static void op_send(void *ctx, const uint8_t *packet, size_t length)
{
	(void)ctx;
	if (write(usb, packet, length) != (ssize_t)length)
		write_errors++;
}

static void *log_pump(void *arg)
{
	int fd = (int)(intptr_t)arg;
	uint8_t reply[4096];
	uint64_t position = 0;
	int one = 1;
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
	for (;;) {
		char byte;
		ssize_t readable = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT);
		if (readable == 0 || (readable < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR))
			break;
		size_t length = sizeof(reply);
		if (sysctlbyname("kern.hakios.usb_log", reply, &length, &position, sizeof(position)) != 0 || length < 12) {
			break;
		}
		uint32_t n;
		memcpy(&position, reply, 8);
		memcpy(&n, reply + 8, 4);
		if (n > length - 12)
			break;
		if (!n) {
			struct pollfd peer = {fd, POLLIN, 0};
			(void)poll(&peer, 1, 250);
			continue;
		}
		for (uint32_t done = 0; done < n;) {
			ssize_t w = write(fd, reply + 12 + done, n - done);
			if (w <= 0) {
				close(fd);
				return NULL;
			}
			done += (uint32_t)w;
		}
	}
	close(fd);
	return NULL;
}

static void put(int fd, const char *format, ...)
{
	char line[1024];
	va_list ap;
	va_start(ap, format);
	int n = vsnprintf(line, sizeof(line), format, ap);
	va_end(ap);
	if (n > 0)
		(void)!write(fd, line, (size_t)(n < (int)sizeof(line) ? n : (int)sizeof(line) - 1));
}

/* QueryType to lockdownd at an address; what came back, or why nothing did */
static void probe_lockdown(int out, const struct sockaddr *addr, socklen_t length, const char *what)
{
	int s = socket(addr->sa_family, SOCK_STREAM, 0);
	if (s < 0) {
		put(out, "%s: socket: %s\n", what, strerror(errno));
		return;
	}
	struct timeval tv = {3, 0};
	setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
	if (connect(s, addr, length) != 0) {
		put(out, "%s: connect: %s\n", what, strerror(errno));
		close(s);
		return;
	}
	const char *body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
	    "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict><key>Label</key><string>hakios</string>"
	    "<key>Request</key><string>QueryType</string></dict></plist>\n";
	uint32_t n = htonl((uint32_t)strlen(body));
	ssize_t w = send(s, &n, 4, 0);
	if (w == 4)
		w = send(s, body, strlen(body), 0);
	char reply[2048];
	ssize_t r = recv(s, reply, sizeof(reply) - 1, MSG_WAITALL);
	int e = errno;
	if (r > 4) {
		reply[r] = 0;
		put(out, "%s: answered %zd bytes: %s\n", what, r, reply + 4);
	} else {
		put(out, "%s: sent %zd, then %s\n", what, w, r == 0 ? "closed by lockdownd" : strerror(e));
	}
	close(s);
}

static void *diag_report(void *arg)
{
	int out = (int)(intptr_t)arg;
	int pids[4096];
	int count = proc_listallpids(pids, sizeof(pids));
	int lockdowns = 0;
	put(out, "== processes: %d\n", count);
	for (int i = 0; i < count; i++) {
		char name[2 * MAXCOMLEN + 1] = "";
		proc_name(pids[i], name, sizeof(name));
		if (strstr(name, "lockdown") || strstr(name, "mobileactivation") || strstr(name, "usbmux")) {
			put(out, "   %d %s\n", pids[i], name);
			lockdowns += strstr(name, "lockdownd") != NULL;
		}
	}
	put(out, "lockdownd processes: %d\n", lockdowns);
	struct ifreq f;
	memset(&f, 0, sizeof(f));
	strlcpy(f.ifr_name, "lo0", sizeof(f.ifr_name));
	int s = socket(AF_INET, SOCK_DGRAM, 0);
	if (s >= 0 && ioctl(s, SIOCGIFFLAGS, &f) == 0)
		put(out, "lo0 flags %#x (%s)\n", f.ifr_flags & 0xffff, (f.ifr_flags & IFF_UP) ? "up" : "DOWN");
	if (s >= 0 && ioctl(s, SIOCGIFADDR, &f) == 0)
		put(out, "lo0 address %s\n", inet_ntoa(((struct sockaddr_in *)&f.ifr_addr)->sin_addr));
	if (s >= 0)
		close(s);
	struct sockaddr_in in;
	memset(&in, 0, sizeof(in));
	in.sin_len = sizeof(in);
	in.sin_family = AF_INET;
	in.sin_port = htons(62078);
	in.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	probe_lockdown(out, (struct sockaddr *)&in, sizeof(in), "TCP 127.0.0.1:62078");
	struct sockaddr_un un;
	memset(&un, 0, sizeof(un));
	un.sun_family = AF_UNIX;
	strlcpy(un.sun_path, "/var/run/lockdown.sock", sizeof(un.sun_path));
	probe_lockdown(out, (struct sockaddr *)&un, sizeof(un), "/var/run/lockdown.sock");
	const char *logs[] = {"/private/var/tmp/lockdownd.err", "/private/var/tmp/lockdownd.out"};
	for (int i = 0; i < 2; i++) {
		int fd = open(logs[i], O_RDONLY);
		if (fd < 0) {
			put(out, "== %s: %s\n", logs[i], strerror(errno));
			continue;
		}
		off_t size = lseek(fd, 0, SEEK_END);
		off_t from = size > 12000 ? size - 12000 : 0;
		lseek(fd, from, SEEK_SET);
		put(out, "== %s (%lld bytes, from %lld)\n", logs[i], (long long)size, (long long)from);
		char buffer[4096];
		ssize_t n;
		while ((n = read(fd, buffer, sizeof(buffer))) > 0)
			(void)!write(out, buffer, (size_t)n);
		close(fd);
	}
	put(out, "== end\n");
	close(out);
	return NULL;
}

extern char **environ;

/* adb shell, the least of it: "/redwood/bin/rwtouch tap 0.5 0.6" runs with its output on the socket */
static void *run_command(void *arg)
{
	int fd = (int)(intptr_t)arg;
	char line[1024];
	size_t n = 0;
	while (n < sizeof(line) - 1) {
		ssize_t r = read(fd, line + n, 1);
		if (r <= 0 || line[n] == '\n')
			break;
		n++;
	}
	line[n] = 0;
	char *argv[64];
	int argc = 0;
	for (char *save = NULL, *t = strtok_r(line, " \t\r", &save); t && argc < 63; t = strtok_r(NULL, " \t\r", &save))
		argv[argc++] = t;
	argv[argc] = NULL;
	if (!argc || strncmp(argv[0], "/redwood/bin/", 13) != 0 || strstr(argv[0], "..")) {
		put(fd, "usbmuxd_dev: only programs of /redwood/bin run here\n");
		close(fd);
		return NULL;
	}
	say("usbmuxd_dev: the Mac runs %s\n", argv[0]);
	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_adddup2(&actions, fd, 1);
	posix_spawn_file_actions_adddup2(&actions, fd, 2);
	posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
	pid_t pid;
	int e = posix_spawn(&pid, argv[0], &actions, NULL, argv, environ);
	posix_spawn_file_actions_destroy(&actions);
	if (e != 0) {
		put(fd, "usbmuxd_dev: %s: %s\n", argv[0], strerror(e));
	} else {
		int status = 0;
		waitpid(pid, &status, 0);
		put(fd, "[exit %d]\n", WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
	}
	close(fd);
	return NULL;
}

static int bring_up_loopback(void)
{
	static int tried;
	if (tried++)
		return -1;
	int s = socket(AF_INET, SOCK_DGRAM, 0);
	if (s < 0)
		return -1;
	struct ifaliasreq a;
	memset(&a, 0, sizeof(a));
	strlcpy(a.ifra_name, "lo0", sizeof(a.ifra_name));
	struct sockaddr_in *addr = (struct sockaddr_in *)&a.ifra_addr, *mask = (struct sockaddr_in *)&a.ifra_mask;
	addr->sin_len = mask->sin_len = sizeof(struct sockaddr_in);
	addr->sin_family = mask->sin_family = AF_INET;
	addr->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	mask->sin_addr.s_addr = htonl(0xff000000);
	int r = ioctl(s, SIOCAIFADDR, &a);
	struct ifreq f;
	memset(&f, 0, sizeof(f));
	strlcpy(f.ifr_name, "lo0", sizeof(f.ifr_name));
	if (ioctl(s, SIOCGIFFLAGS, &f) == 0) {
		f.ifr_flags |= IFF_UP;
		r |= ioctl(s, SIOCSIFFLAGS, &f);
	}
	close(s);
	say("usbmuxd_dev: lo0 brought up for 127.0.0.1: %s\n", r == 0 ? "done" : strerror(errno));
	return r;
}

static int op_open(void *ctx, uint16_t port)
{
	(void)ctx;
	int fd = -1;
	if (port == DIAG_PORT || port == RUN_PORT) {
		int pair[2];
		pthread_t t;
		if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0)
			return -1;
		/* Both socket ends may outlive a host disconnect. Protect the writer before
		 * its thread starts; EPIPE is local to that request, never a daemon-wide signal. */
		int no_sigpipe = 1;
		if (setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe)) ||
		    setsockopt(pair[1], SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe))) {
			close(pair[0]);
			close(pair[1]);
			return -1;
		}
		if (pthread_create(&t, NULL, port == DIAG_PORT ? diag_report : run_command, (void *)(intptr_t)pair[1]) != 0) {
			close(pair[0]);
			close(pair[1]);
			return -1;
		}
		pthread_detach(t);
		fd = pair[0];
	} else if (port == LOG_PORT) {
		int pair[2];
		pthread_t t;
		if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0)
			return -1;
		/* Both socket ends may outlive a host disconnect. Protect the writer before
		 * its thread starts; EPIPE is local to that request, never a daemon-wide signal. */
		int no_sigpipe = 1;
		if (setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe)) ||
		    setsockopt(pair[1], SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe))) {
			close(pair[0]);
			close(pair[1]);
			return -1;
		}
		if (pthread_create(&t, NULL, log_pump, (void *)(intptr_t)pair[1]) != 0) {
			close(pair[0]);
			close(pair[1]);
			return -1;
		}
		pthread_detach(t);
		fd = pair[0];
	} else {
		if (port == 62078 && getenv("HAKIOS_LOCKDOWN_UNIX")) {
			/* lockdownd's Unix socket is for local, entitled clients; a Mac comes in over TCP (kept for trying) */
			struct sockaddr_un un;
			memset(&un, 0, sizeof(un));
			un.sun_family = AF_UNIX;
			strlcpy(un.sun_path, "/var/run/lockdown.sock", sizeof(un.sun_path));
			fd = socket(AF_UNIX, SOCK_STREAM, 0);
			if (fd >= 0 && connect(fd, (struct sockaddr *)&un, sizeof(un)) != 0) {
				close(fd);
				fd = -1;
			}
		}
		for (int attempt = 0; fd < 0 && attempt < 2; attempt++) {
			struct sockaddr_in in;
			memset(&in, 0, sizeof(in));
			in.sin_len = sizeof(in);
			in.sin_family = AF_INET;
			in.sin_port = htons(port);
			in.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
			fd = socket(AF_INET, SOCK_STREAM, 0);
			int e = 0;
			if (fd >= 0) {
				/* at most 3 s: a service that does not accept must not stop the mux */
				fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
				if (connect(fd, (struct sockaddr *)&in, sizeof(in)) != 0) {
					e = errno;
					if (e == EINPROGRESS) {
						struct pollfd w = {fd, POLLOUT, 0};
						socklen_t l = sizeof(e);
						e = poll(&w, 1, 3000) == 1 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &l) == 0 ? e : ETIMEDOUT;
					}
				}
			}
			if (fd >= 0 && e != 0) {
				close(fd);
				fd = -1;
				if (attempt == 0 && (e == ENETUNREACH || e == EADDRNOTAVAIL || e == EHOSTUNREACH) &&
				    bring_up_loopback() == 0)
					continue;
				if (refused++ < 20)
					say("usbmuxd_dev: port %u refused: %s\n", port, strerror(e));
				break;
			}
		}
	}
	if (fd >= 0) {
		int one = 1;
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
		if (opened++ < 40)
			say("usbmuxd_dev: the Mac opened port %u (fd %d)\n", port, fd);
		poke();
	}
	return fd;
}

static void op_deliver(void *ctx, int fd, const uint8_t *data, size_t length)
{
	(void)ctx;
	if (fd < 0 || fd >= MAX_FD)
		return;
	while (length && !pending_length[fd]) {
		ssize_t n = send(fd, data, length, MSG_DONTWAIT);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			break;
		data += n;
		length -= (size_t)n;
	}
	if (!length)
		return;
	if (pending_length[fd] + length > PENDING_MAX) {
		overflowed++;
		shutdown(fd, SHUT_RDWR);    /* the socket thread resets the connection */
		return;
	}
	pending[fd] = realloc(pending[fd], pending_length[fd] + length);
	memcpy(pending[fd] + pending_length[fd], data, length);
	pending_length[fd] += length;
	delivered_late++;
	poke();
}

static void flush_pending(int fd)
{
	size_t done = 0;
	while (done < pending_length[fd]) {
		ssize_t n = send(fd, pending[fd] + done, pending_length[fd] - done, MSG_DONTWAIT);
		if (n <= 0)
			break;
		done += (size_t)n;
	}
	memmove(pending[fd], pending[fd] + done, pending_length[fd] - done);
	pending_length[fd] -= done;
}

static void op_closed(void *ctx, int fd)
{
	(void)ctx;
	if (fd >= 0 && fd < MAX_FD) {
		free(pending[fd]);
		pending[fd] = NULL;
		pending_length[fd] = 0;
	}
	close(fd);
	poke();
}

static const struct usbmux_ops ops = {op_send, op_open, op_deliver, op_closed};

/* ---- the two threads ---- */

static void *usb_reader(void *arg)
{
	(void)arg;
	static uint8_t buffer[65536];
	for (;;) {
		ssize_t n = read(usb, buffer, sizeof(buffer));
		if (n <= 0) {
			if (n < 0 && errno != EINTR)
				usleep(10000);
			continue;
		}
		pthread_mutex_lock(&lock);
		usbmux_input(&mux, buffer, (size_t)n);
		pthread_mutex_unlock(&lock);
		poke();
	}
	return NULL;
}

static void sockets(void)
{
	static uint8_t buffer[USBMUX_MAX_DATA * 4];
	struct pollfd p[USBMUX_CONNS + 1];
	uint64_t last_said = 0;
	for (;;) {
		int count = 0;
		p[count++] = (struct pollfd){wake[0], POLLIN, 0};
		pthread_mutex_lock(&lock);
		for (int i = 0; i < USBMUX_CONNS; i++) {
			int fd = mux.conn[i].fd;
			short events = (short)((usbmux_window(&mux, &mux.conn[i]) ? POLLIN : 0) |
			    (fd >= 0 && fd < MAX_FD && pending_length[fd] ? POLLOUT : 0));
			if (mux.conn[i].used && events)
				p[count++] = (struct pollfd){fd, events, 0};
		}
		pthread_mutex_unlock(&lock);
		poll(p, (nfds_t)count, 1000);
		if (p[0].revents) {
			char drain[64];
			(void)!read(wake[0], drain, sizeof(drain));
		}
		pthread_mutex_lock(&lock);
		for (int i = 1; i < count; i++) {
			if (!p[i].revents)
				continue;
			struct usbmux_conn *c = usbmux_find_fd(&mux, p[i].fd);
			if (!c)
				continue;
			if ((p[i].revents & POLLOUT) && p[i].fd < MAX_FD && pending_length[p[i].fd])
				flush_pending(p[i].fd);
			if (!(p[i].revents & (POLLIN | POLLHUP | POLLERR)))
				continue;
			size_t room = usbmux_window(&mux, c);
			if (room > sizeof(buffer))
				room = sizeof(buffer);
			ssize_t n = recv(c->fd, buffer, room, MSG_DONTWAIT);
			if (n < 0 && (errno == EAGAIN || errno == EINTR))
				continue;
			if (n <= 0)
				usbmux_close(&mux, c);
			else
				usbmux_send(&mux, c, buffer, (size_t)n);
		}
		uint64_t now = (uint64_t)time(NULL);
		if (now - last_said >= 10) {
			int live = 0;
			for (int i = 0; i < USBMUX_CONNS; i++)
				live += mux.conn[i].used;
			if (mux.packets_in || last_said == 0)
				say("usbmuxd_dev: version %d, %d connections; in %llu packets %llu bytes, out %llu packets %llu bytes, "
				    "%llu resets, %llu dropped, %llu write errors, %llu late deliveries, %llu overflows\n", mux.version, live,
				    mux.packets_in, mux.bytes_in, mux.packets_out, mux.bytes_out, mux.resets, mux.dropped, write_errors,
				    delivered_late, overflowed);
			last_said = now;
		}
		pthread_mutex_unlock(&lock);
	}
}

static int copy_udid(char *out, size_t size)
{
	void *mg = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
	CFTypeRef (*copy_answer)(CFStringRef) = mg ? (CFTypeRef (*)(CFStringRef))dlsym(mg, "MGCopyAnswer") : NULL;
	if (!copy_answer)
		return -1;
	CFTypeRef value = copy_answer(CFSTR("UniqueDeviceID"));
	int ok = value && CFGetTypeID(value) == CFStringGetTypeID() &&
	    CFStringGetCString(value, out, (CFIndex)size, kCFStringEncodingUTF8);
	if (value)
		CFRelease(value);
	return ok && strlen(out) >= 8 ? 0 : -1;
}

int main(void)
{
	char udid[64] = "";
	for (int i = 0; i < 300 && (usb = open("/dev/hakios-usbmux", O_RDWR)) < 0; i++)
		usleep(100000);
	if (usb < 0) {
		say("usbmuxd_dev: no /dev/hakios-usbmux (boot-arg usb=2?): %s\n", strerror(errno));
		return 1;
	}
	for (int i = 0; i < 60 && copy_udid(udid, sizeof(udid)) != 0; i++)
		sleep(1);
	if (udid[0]) {
		int r = sysctlbyname("kern.hakios.usb_serial", NULL, NULL, udid, strlen(udid) + 1);
		say("usbmuxd_dev: the USB serial number is lockdownd's UDID (%zu characters)%s\n", strlen(udid),
		    r == 0 ? "" : ", but the kernel refused it");
	} else {
		say("usbmuxd_dev: MobileGestalt gave no UniqueDeviceID; the kernel uses its stand-in\n");
	}
	if (pipe(wake) != 0)
		return 1;
	fcntl(wake[0], F_SETFL, O_NONBLOCK);
	fcntl(wake[1], F_SETFL, O_NONBLOCK);
	usbmux_init(&mux, &ops, NULL);
	pthread_t reader;
	if (pthread_create(&reader, NULL, usb_reader, NULL) != 0)
		return 1;
	say("usbmuxd_dev: serving the Mac's usbmuxd (lockdownd 62078, live log %d)\n", LOG_PORT);
	sockets();
	return 0;
}

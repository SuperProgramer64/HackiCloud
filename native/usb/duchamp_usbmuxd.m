// SPDX-License-Identifier: MIT
// duchamp_usbmuxd: the Mac's end of the USB multiplexer for the POCO (usb=2), through IOUSBHost.
//
// Apple's usbmuxd reaches iPhones through the legacy IOUSBLib user clients, which this Mac (macOS 26 on an AMD
// board) refuses for every device (IOCreatePlugInInterfaceForService: kIOReturnNoResources / Unsupported), and it
// only switches a phone's configuration when IOKit has set kCDCDoNotMatchThisDevice, which this USB controller
// never gets. IOUSBHost works here, so this program opens the POCO's mux interface (255/254/2) itself, speaks the
// device side's protocol (duchamp-userland/usbmux/usbmux_core.h is the other end) and serves usbmuxd's own plist
// protocol on a Unix socket (default /tmp/hakios-usbmuxd; USBMUXD_SOCKET_ADDRESS=UNIX:/tmp/hakios-usbmuxd for
// libimobiledevice tools). Pair records are kept in ~/Library/Application Support/HackiCloud/usb/pair-records.
//
//   clang -fobjc-arc -O2 tools/duchamp_usbmuxd.m -framework Foundation -framework IOKit -framework IOUSBHost -o duchamp_usbmuxd
//   ./duchamp_usbmuxd [/path/of/socket]
#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <launch.h>
#include <mach-o/dyld.h>
#include <fcntl.h>
#include <limits.h>
#include <unistd.h>
#include "usbmux_handshake.h"

enum { V_VERSION = 0, V_SETUP = 2, V_TCP = 6 };
enum { FIN = 1, SYN = 2, RST = 4, ACK = 0x10 };
enum { CONNS = 64, MAX_DATA = 16000, OUR_WINDOW = 512 };

struct conn {
	int used, state;              // 0 connecting, 1 connected, 2 refused, 3 closed
	int fd;
	uint16_t sport, dport;        // ours (the host's) and the phone's
	uint32_t seq, ack;            // our next sequence; the phone's next
	uint32_t dev_ack, dev_win;    // what the phone acknowledged of ours; its window in bytes
	int ready;                    // the client has had its Connect answer: the phone's bytes may go to it
	uint8_t *pending;             // the phone's bytes until then
	size_t pending_length;
};

static IOUSBHostInterface *interface;
static IOUSBHostPipe *pipe_in, *pipe_out;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER, out_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static struct conn conns[CONNS];
static int version, attached;
static uint16_t tx_seq, rx_seq = 0xffff, next_port = 0x8000;
static NSString *udid, *store;
/* clients that sent Listen: told of every attach and detach, as Apple's usbmuxd tells them (trial 165: Finder's
 * AMPDeviceDiscoveryAgent listened before the phone came and was never told) */
static int listeners[64];
static pthread_mutex_t listeners_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t location;

static void be32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static void be16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = v; }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }

static void say(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void say(NSString *format, ...)
{
	va_list ap;
	va_start(ap, format);
	NSString *s = [[NSString alloc] initWithFormat:format arguments:ap];
	va_end(ap);
	fprintf(stderr, "[duchamp_usbmuxd %s] %s\n", [[NSDate.date description] UTF8String], s.UTF8String);
}

static BOOL usb_send(const uint8_t *bytes, size_t length)
{
	@autoreleasepool {
	pthread_mutex_lock(&out_lock);
	NSMutableData *data = [NSMutableData dataWithBytes:bytes length:length];
	NSUInteger done = 0;
	NSError *error = nil;
	BOOL ok = pipe_out && [pipe_out sendIORequestWithData:data bytesTransferred:&done completionTimeout:5 error:&error];
	pthread_mutex_unlock(&out_lock);
	if (!ok)
		say(@"USB OUT failed: %@", error);
	return ok;
	}
}

static int resync_send(void *context,const uint8_t *bytes,size_t length)
{
	(void)context;return usb_send(bytes,length);
}

// with the lock held
static void tcp_send(struct conn *c, uint8_t flags, const uint8_t *data, size_t n)
{
	uint8_t packet[16 + 20 + MAX_DATA];
	size_t total = 16 + 20 + n;
	be32(packet, V_TCP);
	be32(packet + 4, (uint32_t)total);
	be32(packet + 8, 0xfeedface);
	be16(packet + 12, tx_seq++);
	be16(packet + 14, rx_seq);
	uint8_t *t = packet + 16;
	memset(t, 0, 20);
	be16(t, c->sport);
	be16(t + 2, c->dport);
	be32(t + 4, c->seq);
	be32(t + 8, c->ack);
	t[12] = 5 << 4;
	t[13] = flags;
	be16(t + 14, OUR_WINDOW);
	if (n)
		memcpy(t + 20, data, n);
	usb_send(packet, total);
}

static struct conn *find(uint16_t sport, uint16_t dport)
{
	for (int i = 0; i < CONNS; i++)
		if (conns[i].used && conns[i].sport == sport && conns[i].dport == dport)
			return &conns[i];
	return NULL;
}

static void drop(struct conn *c)
{
	if (c->fd >= 0)
		shutdown(c->fd, SHUT_RDWR);
	c->state = 3;
	pthread_cond_broadcast(&changed);
}

static void tcp_in(const uint8_t *t, size_t length)
{
	if (length < 20)
		return;
	size_t off = (size_t)(t[12] >> 4) * 4;
	if (off < 20 || off > length)
		return;
	uint16_t dport = rd16(t), sport = rd16(t + 2);
	uint32_t seq = rd32(t + 4), ack = rd32(t + 8);
	uint8_t flags = t[13];
	size_t n = length - off;
	struct conn *c = find(sport, dport);
	if (!c)
		return;
	c->dev_win = (uint32_t)rd16(t + 14) << 8;
	if (flags & ACK)
		c->dev_ack = ack;
	if (flags & RST) {
		c->state = c->state == 0 ? 2 : 3;
		drop(c);
		return;
	}
	if (c->state == 0) {
		if ((flags & (SYN | ACK)) == (SYN | ACK)) {
			c->ack = seq + 1;
			c->seq = 1;
			c->state = 1;
			tcp_send(c, ACK, NULL, 0);
		}
		pthread_cond_broadcast(&changed);
		return;
	}
	if (n && c->state == 1 && seq == c->ack && !c->ready) {
		c->pending = realloc(c->pending, c->pending_length + n);
		memcpy(c->pending + c->pending_length, t + off, n);
		c->pending_length += n;
		c->ack += (uint32_t)n;
		tcp_send(c, ACK, NULL, 0);
	} else if (n && c->state == 1 && seq == c->ack) {
		const uint8_t *p = t + off;
		size_t left = n;
		while (left) {
			ssize_t w = send(c->fd, p, left, 0);
			if (w <= 0)
				break;
			p += w;
			left -= (size_t)w;
		}
		c->ack += (uint32_t)n;
		tcp_send(c, ACK, NULL, 0);
	}
	pthread_cond_broadcast(&changed);
}

static void *usb_reader(void *arg)
{
	(void)arg;
	static uint8_t stream[1 << 18];
	size_t have = 0;
	for (;;) {
		@autoreleasepool {
		NSMutableData *buffer = [NSMutableData dataWithLength:16384];
		NSUInteger n = 0;
		NSError *error = nil;
		if (![pipe_in sendIORequestWithData:buffer bytesTransferred:&n completionTimeout:0 error:&error]) {
			say(@"USB IN ended: %@", error);
			pthread_mutex_lock(&lock);
			attached = 0;
			for (int i = 0; i < CONNS; i++)
				if (conns[i].used)
					drop(&conns[i]);
			pthread_mutex_unlock(&lock);
			return NULL;
		}
		if (have + n > sizeof(stream))
			have = 0;
		memcpy(stream + have, buffer.bytes, n);
		have += n;
		size_t at = 0;
		pthread_mutex_lock(&lock);
		while (have - at >= 8) {
			const uint8_t *p = stream + at;
			uint32_t protocol = rd32(p), total = rd32(p + 4);
			size_t header = (protocol == V_VERSION || version < 2) ? 8 : 16;
			if (total < header || total > sizeof(stream)) {
				say(@"lost framing (protocol %u length %u)", protocol, total);
				at = have;
				break;
			}
			if (have - at < total)
				break;
			if (header == 16)
				rx_seq = rd16(p + 12);
			if (protocol == V_VERSION && total >= 20) {
				version = (int)rd32(p + 8);
				say(@"the phone speaks mux version %d.%u", version, rd32(p + 12));
				pthread_cond_broadcast(&changed);
			} else if (protocol == V_TCP) {
				tcp_in(p + header, total - header);
			}
			at += total;
		}
		pthread_mutex_unlock(&lock);
		memmove(stream, stream + at, have - at);
		have -= at;
		}
	}
}

// ---- a connection's client side: bytes from the local socket to the phone ----
static void *client_pump(void *arg)
{
	struct conn *c = arg;
	uint8_t buffer[MAX_DATA];
	for (;;) {
		ssize_t n = recv(c->fd, buffer, sizeof(buffer), 0);
		pthread_mutex_lock(&lock);
		if (n <= 0 || c->state != 1) {
			if (c->state == 1)
				tcp_send(c, RST | ACK, NULL, 0);
			close(c->fd);
			memset(c, 0, sizeof(*c));
			c->fd = -1;
			pthread_mutex_unlock(&lock);
			return NULL;
		}
		size_t done = 0;
		while (done < (size_t)n && c->state == 1) {
			uint32_t in_flight = c->seq - c->dev_ack;
			uint32_t room = in_flight >= c->dev_win ? 0 : c->dev_win - in_flight;
			if (!room) {
				struct timespec ts = {time(NULL) + 1, 0};
				pthread_cond_timedwait(&changed, &lock, &ts);
				continue;
			}
			size_t k = (size_t)n - done;
			if (k > room)
				k = room;
			tcp_send(c, ACK, buffer + done, k);
			c->seq += (uint32_t)k;
			done += k;
		}
		pthread_mutex_unlock(&lock);
	}
}

// ---- usbmuxd's plist protocol ----
static BOOL reply(int fd, uint32_t tag, NSDictionary *message)
{
	NSData *body = [NSPropertyListSerialization dataWithPropertyList:message format:NSPropertyListXMLFormat_v1_0
	    options:0 error:nil];
	uint32_t header[4] = {(uint32_t)(16 + body.length), 1, 8, tag};
	return send(fd, header, 16, 0) == 16 && send(fd, body.bytes, body.length, 0) == (ssize_t)body.length;
}

static NSDictionary *device_properties(void)
{
	return @{@"ConnectionType": @"USB", @"DeviceID": @1, @"LocationID": @(location), @"ProductID": @0x12a8,
	    @"SerialNumber": udid ?: @"", @"USBSerialNumber": udid ?: @"", @"ConnectionSpeed": @480000000};
}

static NSDictionary *attached_message(void)
{
	return @{@"MessageType": @"Attached", @"DeviceID": @1, @"Properties": device_properties()};
}

static void listener_add(int fd)
{
	pthread_mutex_lock(&listeners_lock);
	for (int i = 0; i < 64; i++)
		if (!listeners[i]) {
			listeners[i] = fd;
			break;
		}
	pthread_mutex_unlock(&listeners_lock);
}

static void listener_remove(int fd)
{
	pthread_mutex_lock(&listeners_lock);
	for (int i = 0; i < 64; i++)
		if (listeners[i] == fd)
			listeners[i] = 0;
	pthread_mutex_unlock(&listeners_lock);
}

static void tell_listeners(NSDictionary *message)
{
	pthread_mutex_lock(&listeners_lock);
	for (int i = 0; i < 64; i++)
		if (listeners[i])
			reply(listeners[i], 0, message);
	pthread_mutex_unlock(&listeners_lock);
}

static NSString *record_path(NSString *name)
{
	return [store stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"plist"]];
}

static NSString *system_buid(void)
{
	NSString *path = record_path(@"SystemConfiguration");
	NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
	if (!d[@"SystemBUID"]) {
		d = @{@"SystemBUID": NSUUID.UUID.UUIDString};
		[d writeToFile:path atomically:YES];
	}
	return d[@"SystemBUID"];
}

static int open_connection(int fd, uint16_t port)
{
	pthread_mutex_lock(&lock);
	struct conn *c = NULL;
	for (int i = 0; i < CONNS && !c; i++)
		if (!conns[i].used)
			c = &conns[i];
	if (!c || !attached || version < 2) {
		pthread_mutex_unlock(&lock);
		return 1;
	}
	memset(c, 0, sizeof(*c));
	c->used = 1;
	c->fd = fd;
	c->sport = next_port++;
	if (next_port < 0x8000)
		next_port = 0x8000;
	c->dport = port;
	tcp_send(c, SYN, NULL, 0);
	struct timespec ts = {time(NULL) + 5, 0};
	while (c->state == 0)
		if (pthread_cond_timedwait(&changed, &lock, &ts) != 0)
			break;
	int state = c->state;
	if (state != 1) {
		memset(c, 0, sizeof(*c));
		c->fd = -1;
	}
	pthread_mutex_unlock(&lock);
	if (state != 1) {
		say(@"port %u refused by the phone", port);
		return 3;
	}
	say(@"connected to port %u", port);
	return 0;
}

static void *client(void *arg)
{
	int fd = (int)(intptr_t)arg;
	for (;;) {
		@autoreleasepool {
		uint32_t header[4];
		if (recv(fd, header, 16, MSG_WAITALL) != 16 || header[0] < 16 || header[0] > (1u << 20))
			break;
		NSMutableData *body = [NSMutableData dataWithLength:header[0] - 16];
		if (body.length && recv(fd, body.mutableBytes, body.length, MSG_WAITALL) != (ssize_t)body.length)
			break;
		uint32_t tag = header[3];
		NSDictionary *m = [NSPropertyListSerialization propertyListWithData:body options:0 format:NULL error:nil];
		NSString *type = m[@"MessageType"];
		if (getenv("HAKIOS_USBMUXD_TRACE"))
			say(@"<- %@ (tag %u) from %@", type, tag, m[@"ProgName"]);
		if ([type isEqual:@"ListDevices"]) {
			reply(fd, tag, @{@"DeviceList": attached ? @[attached_message()] : @[]});
		} else if ([type isEqual:@"Listen"]) {
			reply(fd, tag, @{@"MessageType": @"Result", @"Number": @0});
			if (attached && version >= 2)
				reply(fd, 0, attached_message());
			listener_add(fd);
			continue;   // the client keeps the socket for notifications
		} else if ([type isEqual:@"Connect"]) {
			uint16_t port = ntohs((uint16_t)[m[@"PortNumber"] unsignedIntValue]);
			int result = open_connection(fd, port);
			reply(fd, tag, @{@"MessageType": @"Result", @"Number": @(result)});
			if (result == 0) {
				pthread_mutex_lock(&lock);
				struct conn *c = NULL;
				for (int i = 0; i < CONNS && !c; i++)
					if (conns[i].used && conns[i].fd == fd)
						c = &conns[i];
				if (c) {
					if (c->pending_length)
						send(fd, c->pending, c->pending_length, 0);
					free(c->pending);
					c->pending = NULL;
					c->pending_length = 0;
					c->ready = 1;
				}
				pthread_mutex_unlock(&lock);
				if (c)
					client_pump(c);
				return NULL;
			}
		} else if ([type isEqual:@"ReadBUID"]) {
			reply(fd, tag, @{@"BUID": system_buid()});
		} else if ([type isEqual:@"ReadPairRecord"]) {
			NSData *record = [NSData dataWithContentsOfFile:record_path(m[@"PairRecordID"])];
			reply(fd, tag, record ? @{@"PairRecordData": record} : @{@"MessageType": @"Result", @"Number": @2});
		} else if ([type isEqual:@"SavePairRecord"]) {
			BOOL ok = [m[@"PairRecordData"] writeToFile:record_path(m[@"PairRecordID"]) atomically:YES];
			say(@"pair record for %@ saved: %d", m[@"PairRecordID"], ok);
			reply(fd, tag, @{@"MessageType": @"Result", @"Number": @(ok ? 0 : 1)});
		} else if ([type isEqual:@"DeletePairRecord"]) {
			[NSFileManager.defaultManager removeItemAtPath:record_path(m[@"PairRecordID"]) error:nil];
			reply(fd, tag, @{@"MessageType": @"Result", @"Number": @0});
		} else {
			say(@"message %@ answered with Result 0: %@", type, m);
			reply(fd, tag, @{@"MessageType": @"Result", @"Number": @0});
		}
		}
	}
	listener_remove(fd);
	close(fd);
	return NULL;
}


// ---- the camera bridge (trial 169): Image Capture and Photos on this Mac open USB cameras through ptpcamerad and the
// legacy IOUSBLib client, which fails here for every device; a mounted volume with a DCIM folder they take as a camera
// (mscamerad). So the POCO's pictures come over its own PTP interface (IOUSBHost) into a cache, and the cache is
// mounted as the volume IPHONE while the phone is attached. ----
static IOUSBHostInterface *ptp_interface;
static IOUSBHostPipe *ptp_in, *ptp_out;
static uint32_t ptp_tx;
static volatile int camera_run;

static void put32le(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static uint32_t get32le(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t get16le(const uint8_t *p) { return p[0] | p[1] << 8; }

static uint16_t ptp_transact(uint16_t code, int n, const uint32_t *params, NSMutableData **data)
{
	uint8_t c[32] = {0};
	put32le(c, 12 + 4 * n); c[4] = 1; c[6] = code; c[7] = code >> 8; put32le(c + 8, ++ptp_tx);
	for (int i = 0; i < n; i++) put32le(c + 12 + 4 * i, params[i]);
	NSError *e = nil; NSUInteger done = 0;
	if (![ptp_out sendIORequestWithData:[NSMutableData dataWithBytes:c length:12 + 4 * n] bytesTransferred:&done completionTimeout:5 error:&e])
		return 0;
	NSMutableData *acc = [NSMutableData data];
	for (;;) {
		NSMutableData *b = [NSMutableData dataWithLength:1 << 20];
		if (![ptp_in sendIORequestWithData:b bytesTransferred:&done completionTimeout:20 error:&e])
			return 0;
		[acc appendBytes:b.bytes length:done];
		if (acc.length < 12) continue;
		const uint8_t *p = acc.bytes;
		uint32_t len = get32le(p);
		if (acc.length < len) continue;
		if (get16le(p + 4) == 2) {
			if (data) *data = [NSMutableData dataWithBytes:p + 12 length:len - 12];
			[acc replaceBytesInRange:NSMakeRange(0, len) withBytes:NULL length:0];
			if (acc.length < 12) continue;
			p = acc.bytes;
		}
		if (get16le(p + 4) == 3)
			return get16le(p + 6);
	}
}

static NSString *ptp_name(const uint8_t *p, size_t at)
{
	uint8_t n = p[at];
	NSMutableString *s = [NSMutableString string];
	for (int i = 0; i < n; i++) { uint16_t ch = get16le(p + at + 1 + 2 * i); if (ch) [s appendFormat:@"%C", (unichar)ch]; }
	return s;
}

static BOOL camera_open(void)
{
	io_iterator_t it = IO_OBJECT_NULL;
	IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &it);
	io_service_t s = IO_OBJECT_NULL, c;
	while ((c = IOIteratorNext(it))) {
		NSNumber *v = CFBridgingRelease(IORegistryEntryCreateCFProperty(c, CFSTR("idVendor"), NULL, 0));
		NSNumber *pr = CFBridgingRelease(IORegistryEntryCreateCFProperty(c, CFSTR("idProduct"), NULL, 0));
		NSNumber *k = CFBridgingRelease(IORegistryEntryCreateCFProperty(c, CFSTR("bInterfaceClass"), NULL, 0));
		if (v.intValue == 0x05ac && pr.intValue == 0x12a8 && k.intValue == 6) { s = c; break; }
		IOObjectRelease(c);
	}
	IOObjectRelease(it);
	if (!s)
		return NO;
	NSError *e = nil;
	ptp_interface = [[IOUSBHostInterface alloc] initWithIOService:s options:IOUSBHostObjectInitOptionsNone queue:nil error:&e interestHandler:nil];
	IOObjectRelease(s);
	if (!ptp_interface) {
		say(@"camera: the PTP interface: %@", e);
		return NO;
	}
	ptp_in = [ptp_interface copyPipeWithAddress:0x82 error:&e];
	ptp_out = [ptp_interface copyPipeWithAddress:0x02 error:&e];
	return ptp_in && ptp_out;
}

static void camera_close(void)
{
	[ptp_interface destroy];
	ptp_interface = nil;
	ptp_in = ptp_out = nil;
}

static int run_tool(NSArray<NSString *> *arguments)
{
	NSTask *t = [NSTask new];
	t.launchPath = @"/usr/bin/hdiutil";
	t.arguments = arguments;
	t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
	t.standardError = [NSFileHandle fileHandleWithNullDevice];
	@try { [t launch]; [t waitUntilExit]; } @catch (NSException *x) { return -1; }
	return t.terminationStatus;
}

/* the phone's DCIM into the cache; returns how many files are there, -1 when the phone did not answer */
static int camera_sync(NSString *cache)
{
	uint32_t one = 1, all[3] = {0xffffffff, 0, 0};
	if (ptp_transact(0x1002, 1, &one, NULL) == 0)
		return -1;
	NSMutableData *handles = nil;
	if (ptp_transact(0x1007, 3, all, &handles) != 0x2001 || handles.length < 4)
		return -1;
	uint32_t n = get32le(handles.bytes);
	NSMutableDictionary<NSNumber *, NSString *> *folders = [NSMutableDictionary dictionary];
	int files = 0, fetched = 0;
	for (uint32_t i = 0; i < n && 4 + 4 * i + 4 <= handles.length; i++) {
		uint32_t h = get32le((const uint8_t *)handles.bytes + 4 + 4 * i);
		NSMutableData *info = nil;
		if (ptp_transact(0x1008, 1, &h, &info) != 0x2001 || info.length < 53)
			continue;
		const uint8_t *q = info.bytes;
		uint16_t format = get16le(q + 4);
		uint32_t size = get32le(q + 8), parent = get32le(q + 38);
		NSString *name = ptp_name(q, 52);
		NSString *base = parent && folders[@(parent)] ? folders[@(parent)] : cache;
		NSString *path = [base stringByAppendingPathComponent:name];
		if (format == 0x3001) {
			folders[@(h)] = path;
			[NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
			continue;
		}
		files++;
		NSDictionary *have = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
		if (have && [have[NSFileSize] unsignedIntValue] == size)
			continue;
		NSMutableData *bytes = nil;
		if (ptp_transact(0x1009, 1, &h, &bytes) == 0x2001 && [bytes writeToFile:path atomically:YES])
			fetched++;
	}
	ptp_transact(0x1003, 0, NULL, NULL);
	if (fetched)
		say(@"camera: %d pictures on the phone, %d new copied", files, fetched);
	return files;
}

static void *camera_thread(void *arg)
{
	(void)arg;
	@autoreleasepool {
		NSString *root = [store stringByDeletingLastPathComponent];
		NSString *cache = [[root stringByAppendingPathComponent:@"camera"] stringByAppendingPathComponent:udid ?: @"phone"];
		NSString *image = [[root stringByAppendingPathComponent:@"camera"] stringByAppendingPathComponent:@"IPHONE.dmg"];
		[NSFileManager.defaultManager createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
		int shown = -2;
		for (int i = 0; i < 20 && camera_run && !camera_open(); i++)
			sleep(1);
		while (camera_run && ptp_interface) {
			@autoreleasepool {
			int files = camera_sync(cache);
			if (files >= 0 && files != shown) {
				run_tool(@[@"detach", @"/Volumes/IPHONE", @"-force"]);
				run_tool(@[@"create", @"-ov", @"-quiet", @"-fs", @"MS-DOS", @"-volname", @"IPHONE", @"-srcfolder", cache, image]);
				int r = run_tool(@[@"attach", image]);
				say(@"camera: IPHONE mounted for Image Capture and Photos (%d pictures)%@", files, r ? @" -- hdiutil attach failed" : @"");
				shown = files;
			}
			for (int k = 0; k < 20 && camera_run; k++)
				sleep(1);
			}
		}
		camera_close();
		run_tool(@[@"detach", @"/Volumes/IPHONE", @"-force"]);
	}
	return NULL;
}

static BOOL open_phone(void)
{
	CFMutableDictionaryRef match = [IOUSBHostInterface createMatchingDictionaryWithVendorID:@0x05ac productID:@0x12a8
	    bcdDevice:nil interfaceNumber:nil configurationValue:nil interfaceClass:@255 interfaceSubclass:@254
	    interfaceProtocol:@2 speed:nil productIDArray:nil];
	io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, match);
	if (!service)
		return NO;
	CFTypeRef serial = IORegistryEntrySearchCFProperty(service, kIOServicePlane, CFSTR("USB Serial Number"), NULL,
	    kIORegistryIterateRecursively | kIORegistryIterateParents);
	CFTypeRef loc = IORegistryEntrySearchCFProperty(service, kIOServicePlane, CFSTR("locationID"), NULL,
	    kIORegistryIterateRecursively | kIORegistryIterateParents);
	udid = serial ? (__bridge_transfer NSString *)serial : @"";
	location = loc ? [(__bridge_transfer NSNumber *)loc unsignedIntValue] : 0;
	NSError *error = nil;
	interface = [[IOUSBHostInterface alloc] initWithIOService:service options:IOUSBHostObjectInitOptionsNone queue:nil
	    error:&error interestHandler:nil];
	IOObjectRelease(service);
	if (!interface) {
		say(@"opening the mux interface: %@", error);
		return NO;
	}
	pipe_in = [interface copyPipeWithAddress:0x81 error:&error];
	pipe_out = [interface copyPipeWithAddress:0x01 error:&error];
	if (!pipe_in || !pipe_out) {
		say(@"the bulk pipes: %@", error);
		return NO;
	}
	[pipe_in clearStallWithError:nil];
	[pipe_out clearStallWithError:nil];
	return YES;
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		const char *path = argc > 1 ? argv[1] : "/tmp/hakios-usbmuxd";
		/* the pair records: the same folder whether it runs as the owner (tests) or as root for Finder */
		const char *where = getenv("HAKIOS_USBMUXD_STORE");
		store = where ? @(where) : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/HackiCloud/usb/pair-records"];
		[NSFileManager.defaultManager createDirectoryAtPath:store withIntermediateDirectories:YES attributes:nil error:nil];
		for (int i = 0; i < CONNS; i++)
			conns[i].fd = -1;
		/* as a LaunchDaemon (tools/duchamp_finder_mux.sh install) launchd owns /var/run/usbmuxd and hands it over: the
		 * program runs as the owner, not root, and needs no sudo again */
		int server = -1, *fds = NULL;
		size_t nfds = 0;
		BOOL by_launchd = launch_activate_socket("Listeners", &fds, &nfds) == 0 && nfds > 0;
		if (by_launchd) {
			server = fds[0];
			free(fds);
		} else {
			server = socket(AF_UNIX, SOCK_STREAM, 0);
			struct sockaddr_un addr = {.sun_family = AF_UNIX};
			strlcpy(addr.sun_path, path, sizeof(addr.sun_path));
			unlink(path);
			if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(server, 16) != 0) {
				perror("socket");
				return 1;
			}
			chmod(path, 0600);    /* HackiCloud: owner-local socket inside a private directory */
		}
		say(@"usbmuxd protocol on %s; waiting for the POCO (usb=2)", path);
		fcntl(server, F_SETFD, FD_CLOEXEC);
		/* a new build of this program takes over by itself: no second sudo for an update */
		static char self[PATH_MAX];
		uint32_t size = sizeof(self);
		if (_NSGetExecutablePath(self, &size) == 0) {
			static struct timespec built;
			struct stat st;
			if (stat(self, &st) == 0)
				built = st.st_mtimespec;
			static char **saved_argv;
			saved_argv = argv;
			/* static: under ARC a local source is released, and cancelled, when main's block ends */
			static dispatch_source_t timer;
			timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
			    dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
			dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, NSEC_PER_SEC);
			dispatch_source_set_event_handler(timer, ^{
				struct stat now;
				if (stat(self, &now) == 0 && (now.st_mtimespec.tv_sec != built.tv_sec || now.st_mtimespec.tv_nsec != built.tv_nsec)) {
					say(@"a new build of duchamp_usbmuxd: starting it");
					usleep(500000);
					if (by_launchd)
						exit(0);    /* KeepAlive: launchd starts the new one with the same socket */
					execv(self, saved_argv);
				}
			});
			dispatch_resume(timer);
		}
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			for (;;) {
				int fd = accept(server, NULL, NULL);
				if (fd < 0)
					continue;
				int one = 1;
				setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
				fcntl(fd, F_SETFD, FD_CLOEXEC);
				pthread_t t;
				pthread_create(&t, NULL, client, (void *)(intptr_t)fd);
				pthread_detach(t);
			}
		});
		for (;;) {
			@autoreleasepool {
				if (!open_phone()) {
					sleep(1);
					continue;
				}
				pthread_mutex_lock(&lock);
				version = 0;
				tx_seq = 0;
				rx_seq = 0xffff;
				attached = 1;
				pthread_mutex_unlock(&lock);
				pthread_t reader;
				pthread_create(&reader, NULL, usb_reader, NULL);
				/* the phone's daemon may come up after the interface: ask again every 3 s for a minute */
				uint8_t hello[20] = {0, 0, 0, V_VERSION, 0, 0, 0, 20, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0};
				for (int attempt = 0; attempt < 20 && version == 0 && attached; attempt++) {
					if (attempt == 3 && getenv("HAKIOS_USBMUXD_RESYNC")) {
						BOOL recovered=husbmux_resynchronize(resync_send,NULL);
						say(@"bounded mux VERSION resynchronization sent: %@",recovered?@"yes":@"no");
					}
					usb_send(hello, sizeof(hello));
					pthread_mutex_lock(&lock);
					struct timespec ts = {time(NULL) + 3, 0};
					while (version == 0 && attached)
						if (pthread_cond_timedwait(&changed, &lock, &ts) != 0)
							break;
					pthread_mutex_unlock(&lock);
				}
				if (version >= 2) {
					uint8_t setup[17] = {0, 0, 0, V_SETUP, 0, 0, 0, 17, 0xfe, 0xed, 0xfa, 0xce, 0, 0, 0xff, 0xff, 7};
					pthread_mutex_lock(&lock);
					be16(setup + 12, tx_seq++);
					pthread_mutex_unlock(&lock);
					usb_send(setup, sizeof(setup));
					say(@"POCO attached: UDID %@", udid);
					tell_listeners(attached_message());
					camera_run = 1;
					pthread_t camera;
					if (pthread_create(&camera, NULL, camera_thread, NULL) == 0)
						pthread_detach(camera);
				} else {
					say(@"no version answer from the phone");
				}
				pthread_join(reader, NULL);
				[interface destroy];
				interface = nil;
				pipe_in = pipe_out = nil;
				say(@"POCO detached");
				camera_run = 0;
				if (version >= 2)
					tell_listeners(@{@"MessageType": @"Detached", @"DeviceID": @1});
				version = 0;
			}
		}
	}
}

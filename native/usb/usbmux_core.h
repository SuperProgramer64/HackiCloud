/* SPDX-License-Identifier: MIT
 * The device side of the USB multiplexer that a Mac's usbmuxd speaks to an iPhone (protocol as documented by
 * libimobiledevice's usbmuxd, src/device.c): pure, no I/O. The transport hands it the bytes that came in on the bulk
 * OUT endpoint, in any slicing; it answers through ops->send, one mux packet per call (one bulk IN transfer each).
 *
 * Framing: every packet starts with protocol and total length (big-endian); a VERSION packet always has that 8-byte
 * header, every other packet after a version 2 exchange has 16 (magic 0xfeedface, the sender's packet count, the
 * last count it saw). TCP packets carry a 20-byte TCP header: usbmuxd opens with SYN (its sequence 0), expects
 * SYN|ACK with ours at 0, then sends data flagged ACK only; its window is th_win << 8. Either side ends with RST.
 */
#ifndef USBMUX_CORE_H
#define USBMUX_CORE_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>

enum { USBMUX_VERSION = 0, USBMUX_CONTROL = 1, USBMUX_SETUP = 2, USBMUX_TCP = 6 };
enum { USBMUX_FIN = 0x01, USBMUX_SYN = 0x02, USBMUX_RST = 0x04, USBMUX_PSH = 0x08, USBMUX_ACK = 0x10 };
enum {
	USBMUX_CONNS = 32,
	USBMUX_IN_MAX = 140000,
	/* a whole packet stays under the 16 KiB a host reads at once, and is not a multiple of 512 at its largest */
	USBMUX_MAX_DATA = 16384 - 36 - 64,
	USBMUX_OUR_WINDOW = 512,        /* in units of 256 bytes, as iOS advertises */
};

struct usbmux_ops {
	void (*send)(void *ctx, const uint8_t *packet, size_t length);
	int (*open)(void *ctx, uint16_t port);                 /* a local socket for the port, or -1 */
	void (*deliver)(void *ctx, int fd, const uint8_t *data, size_t length);
	void (*closed)(void *ctx, int fd);
};

struct usbmux_conn {
	int used, fd;
	uint16_t port, host_port;       /* ours (the service's) and the host's */
	uint32_t seq, ack;              /* our next sequence number; the host's next one */
	uint32_t host_ack, host_window; /* what the host has acknowledged of ours, and its window in bytes */
};

struct usbmux {
	int version;
	uint16_t tx_seq, rx_seq;
	struct usbmux_conn conn[USBMUX_CONNS];
	const struct usbmux_ops *ops;
	void *ctx;
	size_t in_len;
	uint8_t in[USBMUX_IN_MAX];
	uint8_t out[16 + 20 + USBMUX_MAX_DATA];
	/* counters for the log */
	uint64_t packets_in, packets_out, bytes_in, bytes_out, resets, dropped;
};

static inline uint32_t usbmux_rd32(const uint8_t *p)
{ return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static inline uint16_t usbmux_rd16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static inline void usbmux_wr32(uint8_t *p, uint32_t v)
{ p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v; }
static inline void usbmux_wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }

static inline void usbmux_init(struct usbmux *m, const struct usbmux_ops *ops, void *ctx)
{
	memset(m, 0, sizeof(*m));
	m->ops = ops;
	m->ctx = ctx;
	m->rx_seq = 0xffff;
}

static inline size_t usbmux_header(struct usbmux *m, uint8_t *p, uint32_t protocol, size_t length)
{
	usbmux_wr32(p, protocol);
	usbmux_wr32(p + 4, (uint32_t)length);
	if (m->version < 2 || protocol == USBMUX_VERSION)
		return 8;
	usbmux_wr32(p + 8, 0xfeedface);
	usbmux_wr16(p + 12, m->tx_seq++);
	usbmux_wr16(p + 14, m->rx_seq);
	return 16;
}

static inline size_t usbmux_header_size(const struct usbmux *m) { return m->version >= 2 ? 16 : 8; }

static inline void usbmux_tcp_out(struct usbmux *m, uint16_t port, uint16_t host_port, uint32_t seq, uint32_t ack,
    uint8_t flags, const uint8_t *data, size_t length)
{
	size_t total = usbmux_header_size(m) + 20 + length;
	size_t h = usbmux_header(m, m->out, USBMUX_TCP, total);
	uint8_t *t = m->out + h;
	memset(t, 0, 20);
	usbmux_wr16(t, port);
	usbmux_wr16(t + 2, host_port);
	usbmux_wr32(t + 4, seq);
	usbmux_wr32(t + 8, ack);
	t[12] = 5 << 4;
	t[13] = flags;
	usbmux_wr16(t + 14, USBMUX_OUR_WINDOW);
	if (length)
		memcpy(t + 20, data, length);
	m->packets_out++;
	m->bytes_out += length;
	m->ops->send(m->ctx, m->out, total);
}

static inline struct usbmux_conn *usbmux_find(struct usbmux *m, uint16_t port, uint16_t host_port)
{
	for (int i = 0; i < USBMUX_CONNS; i++)
		if (m->conn[i].used && m->conn[i].port == port && m->conn[i].host_port == host_port)
			return &m->conn[i];
	return NULL;
}

static inline struct usbmux_conn *usbmux_find_fd(struct usbmux *m, int fd)
{
	for (int i = 0; i < USBMUX_CONNS; i++)
		if (m->conn[i].used && m->conn[i].fd == fd)
			return &m->conn[i];
	return NULL;
}

/* bytes the host will take now */
static inline uint32_t usbmux_window(const struct usbmux *m, const struct usbmux_conn *c)
{
	(void)m;
	uint32_t in_flight = c->seq - c->host_ack;
	return in_flight >= c->host_window ? 0 : c->host_window - in_flight;
}

/* the local socket's data to the host, as much as its window allows; returns how much was taken */
static inline size_t usbmux_send(struct usbmux *m, struct usbmux_conn *c, const uint8_t *data, size_t length)
{
	size_t done = 0;
	while (done < length) {
		size_t room = usbmux_window(m, c), n = length - done;
		if (!room)
			break;
		if (n > room)
			n = room;
		if (n > USBMUX_MAX_DATA)
			n = USBMUX_MAX_DATA;
		usbmux_tcp_out(m, c->port, c->host_port, c->seq, c->ack, USBMUX_ACK, data + done, n);
		c->seq += (uint32_t)n;
		done += n;
	}
	return done;
}

static inline void usbmux_drop(struct usbmux *m, struct usbmux_conn *c)
{
	int fd = c->fd;
	memset(c, 0, sizeof(*c));
	m->ops->closed(m->ctx, fd);
}

/* the local side ended: reset the host's connection */
static inline void usbmux_close(struct usbmux *m, struct usbmux_conn *c)
{
	usbmux_tcp_out(m, c->port, c->host_port, c->seq, c->ack, USBMUX_RST | USBMUX_ACK, NULL, 0);
	m->resets++;
	usbmux_drop(m, c);
}

static inline void usbmux_tcp_in(struct usbmux *m, const uint8_t *t, size_t length)
{
	if (length < 20 || (size_t)(t[12] >> 4) * 4 < 20 || (size_t)(t[12] >> 4) * 4 > length) {
		m->dropped++;
		return;
	}
	size_t off = (size_t)(t[12] >> 4) * 4;
	uint16_t host_port = usbmux_rd16(t), port = usbmux_rd16(t + 2);
	uint32_t seq = usbmux_rd32(t + 4), ack = usbmux_rd32(t + 8);
	uint8_t flags = t[13];
	uint32_t window = (uint32_t)usbmux_rd16(t + 14) << 8;
	const uint8_t *data = t + off;
	size_t n = length - off;
	struct usbmux_conn *c = usbmux_find(m, port, host_port);

	if (flags & USBMUX_SYN) {
		if (c)
			usbmux_drop(m, c);
		struct usbmux_conn *free_slot = NULL;
		for (int i = 0; i < USBMUX_CONNS && !free_slot; i++)
			if (!m->conn[i].used)
				free_slot = &m->conn[i];
		int fd = free_slot ? m->ops->open(m->ctx, port) : -1;
		if (fd < 0) {
			usbmux_tcp_out(m, port, host_port, 0, seq + 1, USBMUX_RST | USBMUX_ACK, NULL, 0);
			m->resets++;
			return;
		}
		c = free_slot;
		c->used = 1;
		c->fd = fd;
		c->port = port;
		c->host_port = host_port;
		c->ack = seq + 1;
		c->seq = 0;
		c->host_ack = 1;
		c->host_window = window;
		usbmux_tcp_out(m, port, host_port, 0, c->ack, USBMUX_SYN | USBMUX_ACK, NULL, 0);
		c->seq = 1;
		return;
	}
	if (!c) {
		if (!(flags & USBMUX_RST)) {
			usbmux_tcp_out(m, port, host_port, ack, seq + (uint32_t)n, USBMUX_RST | USBMUX_ACK, NULL, 0);
			m->resets++;
		}
		return;
	}
	if (flags & (USBMUX_RST | USBMUX_FIN)) {
		usbmux_drop(m, c);
		return;
	}
	if (flags & USBMUX_ACK) {
		/* an acknowledgement that moves forward (modulo 2^32) */
		if ((int32_t)(ack - c->host_ack) > 0 && (int32_t)(c->seq - ack) >= 0)
			c->host_ack = ack;
		c->host_window = window;
	}
	if (!n)
		return;
	if (seq == c->ack) {
		c->ack += (uint32_t)n;
		m->bytes_in += n;
		int fd = c->fd;
		m->ops->deliver(m->ctx, fd, data, n);
		c = usbmux_find_fd(m, fd);    /* deliver may have closed it */
		if (!c)
			return;
	} else {
		m->dropped++;
	}
	usbmux_tcp_out(m, c->port, c->host_port, c->seq, c->ack, USBMUX_ACK, NULL, 0);
}

static inline void usbmux_packet(struct usbmux *m, const uint8_t *p, size_t length, size_t header)
{
	uint32_t protocol = usbmux_rd32(p);
	m->packets_in++;
	if (header == 16)
		m->rx_seq = usbmux_rd16(p + 12);
	if (protocol == USBMUX_VERSION) {
		if (length < 8 + 12)
			return;
		uint32_t major = usbmux_rd32(p + 8);
		for (int i = 0; i < USBMUX_CONNS; i++)
			if (m->conn[i].used)
				usbmux_drop(m, &m->conn[i]);
		m->version = major >= 2 ? 2 : 1;
		m->tx_seq = 0;
		m->rx_seq = 0xffff;
		uint8_t reply[20];
		usbmux_header(m, reply, USBMUX_VERSION, sizeof(reply));
		usbmux_wr32(reply + 8, (uint32_t)m->version);
		usbmux_wr32(reply + 12, 0);
		usbmux_wr32(reply + 16, 0);
		m->packets_out++;
		m->ops->send(m->ctx, reply, sizeof(reply));
	} else if (protocol == USBMUX_TCP && m->version) {
		usbmux_tcp_in(m, p + header, length - header);
	}
	/* SETUP, CONTROL: nothing to answer */
}

static inline void usbmux_input(struct usbmux *m, const uint8_t *data, size_t length)
{
	while (length) {
		size_t n = length;
		if (n > sizeof(m->in) - m->in_len)
			n = sizeof(m->in) - m->in_len;
		memcpy(m->in + m->in_len, data, n);
		m->in_len += n;
		data += n;
		length -= n;
		size_t at = 0;
		while (m->in_len - at >= 8) {
			const uint8_t *p = m->in + at;
			uint32_t protocol = usbmux_rd32(p), total = usbmux_rd32(p + 4);
			size_t header = protocol == USBMUX_VERSION ? 8 : usbmux_header_size(m);
			if (total < header || total > sizeof(m->in)) {
				/* lost framing: start again with the next transfer */
				m->dropped++;
				at = m->in_len;
				break;
			}
			if (m->in_len - at < header || m->in_len - at < total)
				break;
			usbmux_packet(m, p, total, header);
			at += total;
		}
		memmove(m->in, m->in + at, m->in_len - at);
		m->in_len -= at;
	}
}
#endif

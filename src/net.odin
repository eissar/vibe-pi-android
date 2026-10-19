package main

// Non-blocking WebSocket client (RFC 6455) over plain TCP, driven by the
// main ALooper. ws:// only (use a LAN / VPN such as Tailscale for remote use).

import "core:c"

foreign import libc_ "system:c"

// Bionic socket API (Bionic's addrinfo puts canonname before addr, unlike glibc).
addrinfo :: struct {
	ai_flags, ai_family, ai_socktype, ai_protocol: c.int,
	ai_addrlen:   u32,
	ai_canonname: cstring,
	ai_addr:      rawptr,
	ai_next:      ^addrinfo,
}
pollfd :: struct {
	fd:      c.int,
	events:  i16,
	revents: i16,
}

SOCK_STREAM  :: 1
IPPROTO_TCP  :: 6
TCP_NODELAY  :: 1
SOL_SOCKET   :: 1
SO_ERROR     :: 4
SO_KEEPALIVE :: 9
O_NONBLOCK   :: 0o4000
O_CLOEXEC    :: 0o2000000
MSG_NOSIGNAL :: 0x4000
EAGAIN       :: 11
EINTR        :: 4
EINPROGRESS  :: 115
POLLIN       :: 1
POLLOUT      :: 4
POLLERR      :: 8
POLLHUP      :: 16

@(default_calling_convention = "c")
foreign libc_ {
	__errno :: proc() -> ^c.int ---
	getaddrinfo :: proc(node, service: cstring, hints: ^addrinfo, res: ^^addrinfo) -> c.int ---
	freeaddrinfo :: proc(res: ^addrinfo) ---
	gai_strerror :: proc(err: c.int) -> cstring ---
	strerror :: proc(err: c.int) -> cstring ---
	socket :: proc(domain, type, protocol: c.int) -> c.int ---
	connect :: proc(fd: c.int, addr: rawptr, len: u32) -> c.int ---
	send :: proc(fd: c.int, buf: rawptr, len: c.size_t, flags: c.int) -> c.ssize_t ---
	recv :: proc(fd: c.int, buf: rawptr, len: c.size_t, flags: c.int) -> c.ssize_t ---
	close :: proc(fd: c.int) -> c.int ---
	setsockopt :: proc(fd: c.int, level, name: c.int, val: rawptr, len: u32) -> c.int ---
	getsockopt :: proc(fd: c.int, level, name: c.int, val: rawptr, len: ^u32) -> c.int ---
	poll :: proc(fds: [^]pollfd, n: c.ulong, timeout: c.int) -> c.int ---
	arc4random_buf :: proc(buf: rawptr, n: c.size_t) ---
}

errno :: proc "contextless" () -> c.int {return __errno()^}

// Odin's core:c/libc expects glibc's __errno_location; Bionic only has __errno.
@(export, link_name = "__errno_location")
errno_location_shim :: proc "c" () -> ^c.int {return __errno()}

// Called every main-loop iteration: waits up to timeout_ms for socket activity.
net_pump :: proc(timeout_ms: c.int) -> bool {
	cn := &conn
	if cn.state == .Closed || cn.fd < 0 do return false
	pfd := pollfd{fd = cn.fd, events = POLLIN}
	if cn.state == .Connecting || len(cn.wbuf) > 0 do pfd.events |= POLLOUT
	if poll(&pfd, 1, timeout_ms) <= 0 do return false
	ev: c.int
	if pfd.revents & POLLIN != 0 do ev |= EV_READ
	if pfd.revents & POLLOUT != 0 do ev |= EV_WRITE
	if pfd.revents & (POLLERR | POLLHUP) != 0 do ev |= EV_ERROR
	net_on_ready(cn.fd, ev)
	return true
}

EV_READ  :: 1
EV_WRITE :: 2
EV_ERROR :: 4
import "core:encoding/base64"
import "core:strings"
import "core:fmt"

Conn_State :: enum {
	Closed,
	Connecting,
	Handshake,
	Open,
}

Conn :: struct {
	state:     Conn_State,
	fd:        c.int,
	host:      string,
	port:      string,
	path:      string,
	rbuf:      [dynamic]u8,
	wbuf:      [dynamic]u8,
	frag:      [dynamic]u8,
	frag_op:   u8,
	error:     string,
}

conn: Conn

// Parse "host[:port][/path]" or "ws://host:port/path" (or http://).
parse_address :: proc(addr: string) -> (host, port, path: string, ok: bool) {
	a := strings.trim_space(addr)
	for prefix in ([]string{"ws://", "http://", "wss://", "https://"}) {
		if strings.has_prefix(a, prefix) {
			a = a[len(prefix):]
			break
		}
	}
	path = "/rpc"
	if i := strings.index_byte(a, '/'); i >= 0 {
		rest := a[i:]
		a = a[:i]
		if rest != "/" && len(rest) > 0 && strings.has_prefix(rest, "/rpc") do path = rest
		else if q := strings.index_byte(rest, '?'); q >= 0 do path = concat("/rpc", rest[q:], context.allocator)
	}
	port = "7860"
	if strings.has_prefix(a, "[") {
		// [ipv6]:port
		if e := strings.index_byte(a, ']'); e > 0 {
			host = a[1:e]
			if e + 1 < len(a) && a[e + 1] == ':' do port = a[e + 2:]
		}
	} else if i := strings.last_index_byte(a, ':'); i >= 0 {
		host = a[:i]
		port = a[i + 1:]
	} else {
		host = a
	}
	ok = len(host) > 0 && len(port) > 0
	return
}

net_connect :: proc(cn: ^Conn, host, port, path: string) -> bool {
	net_close(cn, "")
	cn.host = strings.clone(host)
	cn.port = strings.clone(port)
	cn.path = strings.clone(path)
	cn.error = ""

	hints := addrinfo {
		ai_family   = 0, // AF_UNSPEC
		ai_socktype = SOCK_STREAM,
	}
	res: ^addrinfo
	chost := strings.clone_to_cstring(host, context.temp_allocator)
	cport := strings.clone_to_cstring(port, context.temp_allocator)
	if rc := getaddrinfo(chost, cport, &hints, &res); rc != 0 || res == nil {
		cn.error = strings.clone(concat("Cannot resolve host: ", string(gai_strerror(rc))))
		return false
	}
	defer freeaddrinfo(res)

	SOCK_NONBLOCK :: O_NONBLOCK
	SOCK_CLOEXEC :: O_CLOEXEC
	fd := socket(res.ai_family, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0)
	if fd < 0 {
		cn.error = strings.clone(concat("socket(): ", string(strerror(errno()))))
		return false
	}
	one: c.int = 1
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, size_of(c.int))
	setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, size_of(c.int))
	rc := connect(fd, res.ai_addr, res.ai_addrlen)
	if rc < 0 && errno() != EINPROGRESS {
		cn.error = strings.clone(concat("connect(): ", string(strerror(errno()))))
		close(fd)
		return false
	}
	cn.fd = fd
	cn.state = .Connecting
	return true
}

net_close :: proc(cn: ^Conn, reason: string) {
	if cn.state != .Closed && cn.fd > 0 {
		close(cn.fd)
	}
	cn.fd = -1
	cn.state = .Closed
	clear(&cn.rbuf)
	clear(&cn.wbuf)
	clear(&cn.frag)
	if len(reason) > 0 {
		cn.error = strings.clone(reason)
	}
}

@(private = "file")
send_handshake :: proc(cn: ^Conn) {
	key_raw: [16]u8
	arc4random_buf(&key_raw[0], 16)
	key := base64.encode(key_raw[:], allocator = context.temp_allocator)
	req := strings.concatenate({
		"GET ", cn.path, " HTTP/1.1\r\n",
		"Host: ", cn.host, ":", cn.port, "\r\n",
		"Upgrade: websocket\r\n",
		"Connection: Upgrade\r\n",
		"Sec-WebSocket-Key: ", key, "\r\n",
		"Sec-WebSocket-Version: 13\r\n",
		"User-Agent: PiAgent-Android-Odin\r\n",
		"\r\n",
	}, context.temp_allocator)
	append(&cn.wbuf, req)
	flush(cn)
}

@(private = "file")
flush :: proc(cn: ^Conn) -> bool {
	for len(cn.wbuf) > 0 {
		n := send(cn.fd, raw_data(cn.wbuf), c.size_t(len(cn.wbuf)), MSG_NOSIGNAL)
		if n < 0 {
			e := errno()
			if e == EINTR do continue
			if e == EAGAIN {
				return true
			}
			net_close(cn, concat("send(): ", string(strerror(e))))
			app_on_disconnected()
			return false
		}
		remove_range(&cn.wbuf, 0, int(n))
	}
	return true
}

// Queue a masked text frame.
net_send_text :: proc(cn: ^Conn, payload: string) -> bool {
	if cn.state != .Open do return false
	n := len(payload)
	hdr: [14]u8
	hl := 2
	hdr[0] = 0x80 | 0x1 // FIN + text
	if n < 126 {
		hdr[1] = 0x80 | u8(n)
	} else if n < 65536 {
		hdr[1] = 0x80 | 126
		hdr[2] = u8(n >> 8)
		hdr[3] = u8(n)
		hl = 4
	} else {
		hdr[1] = 0x80 | 127
		for i in 0 ..< 8 do hdr[2 + i] = u8(u64(n) >> (56 - 8 * uint(i)))
		hl = 10
	}
	mask: [4]u8
	arc4random_buf(&mask[0], 4)
	copy(hdr[hl:], mask[:])
	hl += 4
	append(&cn.wbuf, ..hdr[:hl])
	start := len(cn.wbuf)
	append(&cn.wbuf, payload)
	for i in 0 ..< n do cn.wbuf[start + i] ~= mask[i & 3]
	return flush(cn)
}

@(private = "file")
send_control :: proc(cn: ^Conn, op: u8, payload: []u8) {
	hdr := [6]u8{0x80 | op, 0x80 | u8(len(payload)), 0, 0, 0, 0}
	arc4random_buf(&hdr[2], 4)
	append(&cn.wbuf, ..hdr[:])
	start := len(cn.wbuf)
	append(&cn.wbuf, ..payload)
	for i in 0 ..< len(payload) do cn.wbuf[start + i] ~= hdr[2 + (i & 3)]
	flush(cn)
}

// Looper callback. Returns false to unregister the fd.
net_on_ready :: proc(fd: c.int, events: c.int) -> bool {
	cn := &conn
	if fd != cn.fd || cn.state == .Closed do return false

	if cn.state == .Connecting {
		if events & (EV_WRITE | EV_ERROR) != 0 {
			err: c.int
			l := u32(size_of(c.int))
			getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &l)
			if err != 0 {
				net_close(cn, concat("Connection failed: ", string(strerror(err))))
				app_on_disconnected()
				return false
			}
			cn.state = .Handshake
			send_handshake(cn)
		}
		return cn.state != .Closed
	}

	if events & EV_WRITE != 0 {
		if !flush(cn) do return false
	}

	if events & (EV_READ | EV_ERROR) != 0 {
		buf: [32768]u8
		for {
			n := recv(fd, &buf[0], len(buf), 0)
			if n > 0 {
				append(&cn.rbuf, ..buf[:n])
				continue
			}
			if n == 0 {
				process_input(cn)
				if cn.state != .Closed {
					net_close(cn, "Server closed the connection")
					app_on_disconnected()
				}
				return false
			}
			e := errno()
			if e == EINTR do continue
			if e == EAGAIN do break
			net_close(cn, concat("recv(): ", string(strerror(e))))
			app_on_disconnected()
			return false
		}
		process_input(cn)
	}
	return cn.state != .Closed
}

@(private = "file")
process_input :: proc(cn: ^Conn) {
	if cn.state == .Handshake {
		s := string(cn.rbuf[:])
		end := strings.index(s, "\r\n\r\n")
		if end < 0 do return
		status_line := s[:max(strings.index(s, "\r\n"), 0)]
		parts := strings.split(status_line, " ", context.temp_allocator)
		if len(parts) < 2 || parts[1] != "101" {
			msg := concat("Handshake rejected: ", status_line)
			if len(parts) >= 2 && (parts[1] == "401" || parts[1] == "403") do msg = "Unauthorized — check the token"
			net_close(cn, msg)
			app_on_disconnected()
			return
		}
		remove_range(&cn.rbuf, 0, end + 4)
		cn.state = .Open
		app_on_connected()
	}
	off := 0
	defer if cn.state == .Open && off > 0 do remove_range(&cn.rbuf, 0, off)
	for cn.state == .Open {
		b := cn.rbuf[off:]
		if len(b) < 2 do return
		fin := b[0] & 0x80 != 0
		op := b[0] & 0x0F
		masked := b[1] & 0x80 != 0
		plen := u64(b[1] & 0x7F)
		hl := 2
		if plen == 126 {
			if len(b) < 4 do return
			plen = u64(b[2]) << 8 | u64(b[3])
			hl = 4
		} else if plen == 127 {
			if len(b) < 10 do return
			plen = 0
			for i in 0 ..< 8 do plen = plen << 8 | u64(b[2 + i])
			hl = 10
		}
		mask: [4]u8
		if masked {
			if len(b) < hl + 4 do return
			copy(mask[:], b[hl:hl + 4])
			hl += 4
		}
		if u64(len(b)) < u64(hl) + plen do return
		payload := b[hl:hl + int(plen)]
		if masked do for i in 0 ..< len(payload) do payload[i] ~= mask[i & 3]

		switch op {
		case 0x0: // continuation
			append(&cn.frag, ..payload)
			if fin {
				if cn.frag_op == 0x1 do app_on_message(string(cn.frag[:]))
				clear(&cn.frag)
			}
		case 0x1, 0x2:
			if fin {
				if op == 0x1 do app_on_message(string(payload))
			} else {
				clear(&cn.frag)
				cn.frag_op = op
				append(&cn.frag, ..payload)
			}
		case 0x8:
			code := len(payload) >= 2 ? int(payload[0]) << 8 | int(payload[1]) : 1005
			send_control(cn, 0x8, payload[:min(len(payload), 2)])
			reason := len(payload) > 2 ? string(payload[2:]) : ""
			net_close(cn, fmt.tprintf("Closed by server (%d) %s", code, reason))
			app_on_disconnected()
			return
		case 0x9:
			send_control(cn, 0xA, payload[:min(len(payload), 125)])
		case 0xA:
		}
		if cn.state != .Open do return
		off += hl + int(plen)
	}
}

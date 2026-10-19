package main

// Minimal hand-written bindings for the Android NDK C APIs we use:
// NativeActivity, ALooper, AInputQueue/AInputEvent, AConfiguration, ANativeWindow, liblog.

import "core:c"

foreign import libandroid "system:android"
foreign import liblog "system:log"
foreign import libc_ "system:c"

ARect :: struct {
	left, top, right, bottom: i32,
}

ANativeActivity :: struct {
	callbacks:        ^ANativeActivityCallbacks,
	vm:               rawptr,
	env:              ^JNIEnv,
	clazz:            jobject,
	internalDataPath: cstring,
	externalDataPath: cstring,
	sdkVersion:       i32,
	instance:         rawptr,
	assetManager:     rawptr,
	obbPath:          cstring,
}

ANativeActivityCallbacks :: struct {
	onStart:                    proc "c" (activity: ^ANativeActivity),
	onResume:                   proc "c" (activity: ^ANativeActivity),
	onSaveInstanceState:        proc "c" (activity: ^ANativeActivity, out_size: ^c.size_t) -> rawptr,
	onPause:                    proc "c" (activity: ^ANativeActivity),
	onStop:                     proc "c" (activity: ^ANativeActivity),
	onDestroy:                  proc "c" (activity: ^ANativeActivity),
	onWindowFocusChanged:       proc "c" (activity: ^ANativeActivity, has_focus: c.int),
	onNativeWindowCreated:      proc "c" (activity: ^ANativeActivity, window: rawptr),
	onNativeWindowResized:      proc "c" (activity: ^ANativeActivity, window: rawptr),
	onNativeWindowRedrawNeeded: proc "c" (activity: ^ANativeActivity, window: rawptr),
	onNativeWindowDestroyed:    proc "c" (activity: ^ANativeActivity, window: rawptr),
	onInputQueueCreated:        proc "c" (activity: ^ANativeActivity, queue: rawptr),
	onInputQueueDestroyed:      proc "c" (activity: ^ANativeActivity, queue: rawptr),
	onContentRectChanged:       proc "c" (activity: ^ANativeActivity, rect: ^ARect),
	onConfigurationChanged:     proc "c" (activity: ^ANativeActivity),
	onLowMemory:                proc "c" (activity: ^ANativeActivity),
}

ALooper_callbackFunc :: proc "c" (fd: c.int, events: c.int, data: rawptr) -> c.int

ALOOPER_EVENT_INPUT  :: 1
ALOOPER_EVENT_OUTPUT :: 2
ALOOPER_EVENT_ERROR  :: 4
ALOOPER_EVENT_HANGUP :: 8

AINPUT_EVENT_TYPE_KEY    :: 1
AINPUT_EVENT_TYPE_MOTION :: 2

AKEY_EVENT_ACTION_DOWN     :: 0
AKEY_EVENT_ACTION_UP       :: 1
AKEY_EVENT_ACTION_MULTIPLE :: 2

AMOTION_EVENT_ACTION_MASK          :: 0xff
AMOTION_EVENT_ACTION_DOWN          :: 0
AMOTION_EVENT_ACTION_UP            :: 1
AMOTION_EVENT_ACTION_MOVE          :: 2
AMOTION_EVENT_ACTION_CANCEL        :: 3
AMOTION_EVENT_ACTION_POINTER_DOWN  :: 5
AMOTION_EVENT_ACTION_POINTER_UP    :: 6
AMOTION_EVENT_ACTION_SCROLL        :: 8
AMOTION_EVENT_AXIS_VSCROLL         :: 9

AKEYCODE_BACK        :: 4
AKEYCODE_DPAD_UP     :: 19
AKEYCODE_DPAD_DOWN   :: 20
AKEYCODE_DPAD_LEFT   :: 21
AKEYCODE_DPAD_RIGHT  :: 22
AKEYCODE_TAB         :: 61
AKEYCODE_SPACE       :: 62
AKEYCODE_ENTER       :: 66
AKEYCODE_DEL         :: 67
AKEYCODE_ESCAPE      :: 111
AKEYCODE_FORWARD_DEL :: 112
AKEYCODE_CTRL_LEFT   :: 113
AKEYCODE_CTRL_RIGHT  :: 114
AKEYCODE_MOVE_HOME   :: 122
AKEYCODE_MOVE_END    :: 123
AKEYCODE_NUMPAD_ENTER :: 160

AMETA_CTRL_ON :: 0x1000
AMETA_SHIFT_ON :: 0x1

ANATIVEACTIVITY_SHOW_SOFT_INPUT_IMPLICIT :: 1
ANATIVEACTIVITY_SHOW_SOFT_INPUT_FORCED   :: 2

ANDROID_LOG_INFO  :: 4
ANDROID_LOG_WARN  :: 5
ANDROID_LOG_ERROR :: 6

@(default_calling_convention = "c")
foreign libandroid {
	ALooper_forThread :: proc() -> rawptr ---
	ALooper_addFd :: proc(looper: rawptr, fd: c.int, ident: c.int, events: c.int, callback: ALooper_callbackFunc, data: rawptr) -> c.int ---
	ALooper_removeFd :: proc(looper: rawptr, fd: c.int) -> c.int ---

	AInputQueue_attachLooper :: proc(queue: rawptr, looper: rawptr, ident: c.int, callback: ALooper_callbackFunc, data: rawptr) ---
	AInputQueue_detachLooper :: proc(queue: rawptr) ---
	AInputQueue_getEvent :: proc(queue: rawptr, out_event: ^rawptr) -> i32 ---
	AInputQueue_preDispatchEvent :: proc(queue: rawptr, event: rawptr) -> i32 ---
	AInputQueue_finishEvent :: proc(queue: rawptr, event: rawptr, handled: c.int) ---

	AInputEvent_getType :: proc(event: rawptr) -> i32 ---
	AInputEvent_getDeviceId :: proc(event: rawptr) -> i32 ---
	AKeyEvent_getAction :: proc(event: rawptr) -> i32 ---
	AKeyEvent_getKeyCode :: proc(event: rawptr) -> i32 ---
	AKeyEvent_getMetaState :: proc(event: rawptr) -> i32 ---
	AKeyEvent_getRepeatCount :: proc(event: rawptr) -> i32 ---
	AMotionEvent_getAction :: proc(event: rawptr) -> i32 ---
	AMotionEvent_getPointerCount :: proc(event: rawptr) -> c.size_t ---
	AMotionEvent_getX :: proc(event: rawptr, pointer_index: c.size_t) -> f32 ---
	AMotionEvent_getY :: proc(event: rawptr, pointer_index: c.size_t) -> f32 ---
	AMotionEvent_getAxisValue :: proc(event: rawptr, axis: i32, pointer_index: c.size_t) -> f32 ---
	AMotionEvent_getEventTime :: proc(event: rawptr) -> i64 ---

	AConfiguration_new :: proc() -> rawptr ---
	AConfiguration_delete :: proc(config: rawptr) ---
	AConfiguration_fromAssetManager :: proc(config: rawptr, am: rawptr) ---
	AConfiguration_getDensity :: proc(config: rawptr) -> i32 ---

	ANativeWindow_getWidth :: proc(window: rawptr) -> i32 ---
	ANativeWindow_getHeight :: proc(window: rawptr) -> i32 ---

	ANativeActivity_finish :: proc(activity: ^ANativeActivity) ---
	ANativeActivity_showSoftInput :: proc(activity: ^ANativeActivity, flags: u32) ---
	ANativeActivity_hideSoftInput :: proc(activity: ^ANativeActivity, flags: u32) ---
}

@(default_calling_convention = "c")
foreign liblog {
	__android_log_write :: proc(prio: c.int, tag: cstring, text: cstring) -> c.int ---
}

// ---------------------------------------------------------------------------
// Bionic libc pieces (sockets, files, timers). Declared here instead of
// core:sys/posix because Bionic differs from glibc (e.g. errno accessor,
// addrinfo field order).
// ---------------------------------------------------------------------------

addrinfo :: struct {
	ai_flags:     c.int,
	ai_family:    c.int,
	ai_socktype:  c.int,
	ai_protocol:  c.int,
	ai_addrlen:   u32,
	ai_canonname: cstring, // NOTE: Bionic (BSD) order: canonname before addr
	ai_addr:      rawptr,
	ai_next:      ^addrinfo,
}

timespec :: struct {
	tv_sec:  i64,
	tv_nsec: i64,
}
itimerspec :: struct {
	it_interval: timespec,
	it_value:    timespec,
}

pollfd :: struct {
	fd:      c.int,
	events:  i16,
	revents: i16,
}

AF_INET      :: 2
SOCK_STREAM  :: 1
IPPROTO_TCP  :: 6
TCP_NODELAY  :: 1
SOL_SOCKET   :: 1
SO_ERROR     :: 4
SO_KEEPALIVE :: 9
F_GETFL      :: 3
F_SETFL      :: 4
O_NONBLOCK   :: 0o4000
O_RDONLY     :: 0
O_WRONLY     :: 1
O_CREAT      :: 0o100
O_TRUNC      :: 0o1000
O_CLOEXEC    :: 0o2000000
MSG_NOSIGNAL :: 0x4000
EAGAIN       :: 11
EINTR        :: 4
EINPROGRESS  :: 115
POLLIN       :: 1
POLLOUT      :: 4
CLOCK_MONOTONIC :: 1
TFD_NONBLOCK :: O_NONBLOCK
TFD_CLOEXEC  :: O_CLOEXEC

@(default_calling_convention = "c")
foreign libc_ {
	__errno :: proc() -> ^c.int ---
	getaddrinfo :: proc(node: cstring, service: cstring, hints: ^addrinfo, res: ^^addrinfo) -> c.int ---
	freeaddrinfo :: proc(res: ^addrinfo) ---
	socket :: proc(domain, type, protocol: c.int) -> c.int ---
	connect :: proc(fd: c.int, addr: rawptr, len: u32) -> c.int ---
	send :: proc(fd: c.int, buf: rawptr, len: c.size_t, flags: c.int) -> c.ssize_t ---
	recv :: proc(fd: c.int, buf: rawptr, len: c.size_t, flags: c.int) -> c.ssize_t ---
	close :: proc(fd: c.int) -> c.int ---
	fcntl :: proc(fd: c.int, cmd: c.int, #c_vararg args: ..any) -> c.int ---
	setsockopt :: proc(fd: c.int, level, name: c.int, val: rawptr, len: u32) -> c.int ---
	getsockopt :: proc(fd: c.int, level, name: c.int, val: rawptr, len: ^u32) -> c.int ---
	poll :: proc(fds: [^]pollfd, n: c.ulong, timeout: c.int) -> c.int ---
	open :: proc(path: cstring, flags: c.int, #c_vararg args: ..any) -> c.int ---
	read :: proc(fd: c.int, buf: rawptr, n: c.size_t) -> c.ssize_t ---
	write :: proc(fd: c.int, buf: rawptr, n: c.size_t) -> c.ssize_t ---
	timerfd_create :: proc(clock: c.int, flags: c.int) -> c.int ---
	timerfd_settime :: proc(fd: c.int, flags: c.int, new_value: ^itimerspec, old: ^itimerspec) -> c.int ---
	clock_gettime :: proc(clock: c.int, ts: ^timespec) -> c.int ---
	gai_strerror :: proc(err: c.int) -> cstring ---
	strerror :: proc(err: c.int) -> cstring ---
	arc4random_buf :: proc(buf: rawptr, n: c.size_t) ---
}

errno :: proc "contextless" () -> c.int {
	return __errno()^
}

// Odin's core:c/libc references glibc's `__errno_location`; Bionic only has `__errno`.
// Provide the alias so any core package that touches errno still links.
@(export, link_name = "__errno_location")
errno_location_shim :: proc "c" () -> ^c.int {
	return __errno()
}

now_ms :: proc "contextless" () -> f64 {
	ts: timespec
	clock_gettime(CLOCK_MONOTONIC, &ts)
	return f64(ts.tv_sec) * 1000 + f64(ts.tv_nsec) / 1e6
}

log_info :: proc(s: string) {
	cs := make([]u8, len(s) + 1, context.temp_allocator)
	copy(cs, s)
	__android_log_write(ANDROID_LOG_INFO, "PiAgent", cstring(raw_data(cs)))
}

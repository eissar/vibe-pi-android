package main

// NativeActivity entry point and platform loop, written directly in Odin.
// Everything runs on the activity's main thread: the main ALooper delivers
// input events, socket readiness and a timerfd that drives redraws.

import "base:runtime"
import "core:c"
import "core:math"

Platform :: struct {
	activity:   ^ANativeActivity,
	looper:     rawptr,
	window:     rawptr,
	queue:      rawptr,
	gfx:        Gfx,
	timer_fd:   c.int,
	timer_due:  f64, // ms timestamp the timer is armed for (0 = disarmed)
	content:    ARect,
	have_content: bool,
	density:    f32,
	resumed:    bool,
	data_dir:   string,
	gl_ready:   bool,
}

plat: Platform
rend: Renderer
g_ctx: runtime.Context
fonts_loaded: bool

@(export)
ANativeActivity_onCreate :: proc "c" (activity: ^ANativeActivity, saved_state: rawptr, saved_size: c.size_t) {
	context = runtime.default_context()
	g_ctx = context

	plat.activity = activity
	plat.looper = ALooper_forThread()
	plat.data_dir = string(activity.internalDataPath)

	cb := activity.callbacks
	cb.onStart = on_start
	cb.onResume = on_resume
	cb.onPause = on_pause
	cb.onStop = on_stop
	cb.onDestroy = on_destroy
	cb.onWindowFocusChanged = on_focus
	cb.onNativeWindowCreated = on_window_created
	cb.onNativeWindowResized = on_window_resized
	cb.onNativeWindowRedrawNeeded = on_window_redraw
	cb.onNativeWindowDestroyed = on_window_destroyed
	cb.onInputQueueCreated = on_input_created
	cb.onInputQueueDestroyed = on_input_destroyed
	cb.onContentRectChanged = on_content_rect
	cb.onConfigurationChanged = on_config_changed
	cb.onLowMemory = nil
	cb.onSaveInstanceState = nil

	update_density()

	if !fonts_loaded {
		load_fonts()
		atlas_init_cpu()
		fonts_loaded = true
	}

	plat.timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC)
	plat.timer_due = 0
	ALooper_addFd(plat.looper, plat.timer_fd, -2, ALOOPER_EVENT_INPUT, on_timer, nil)

	app_init()
	log_info("Pi Agent started")
}

update_density :: proc() {
	cfg := AConfiguration_new()
	AConfiguration_fromAssetManager(cfg, plat.activity.assetManager)
	dpi := AConfiguration_getDensity(cfg)
	AConfiguration_delete(cfg)
	if dpi <= 0 || dpi == 0xffff do dpi = 160
	plat.density = f32(dpi) / 160
	ui.dp = plat.density
}

load_fonts :: proc() {
	try :: proc(id: int, paths: []string) {
		for p in paths {
			data, ok := read_file(p)
			if !ok do continue
			if font_load(&fonts[id], data) {
				log_info(concat("font: ", p))
				return
			}
			delete(data)
		}
	}
	try(FONT_SANS, {"/system/fonts/Roboto-Regular.ttf", "/system/fonts/DroidSans.ttf", "/system/fonts/NotoSans-Regular.ttf"})
	try(FONT_MONO, {"/system/fonts/DroidSansMono.ttf", "/system/fonts/CutiveMono.ttf", "/system/fonts/RobotoMono-Regular.ttf"})
	try(FONT_BOLD, {"/system/fonts/Roboto-Bold.ttf", "/system/fonts/DroidSans-Bold.ttf", "/system/fonts/Roboto-Medium.ttf"})
	if !fonts[FONT_BOLD].ok do fonts[FONT_BOLD] = fonts[FONT_SANS]
}

read_file :: proc(path: string, allocator := context.allocator) -> ([]u8, bool) {
	cpath := make([]u8, len(path) + 1, context.temp_allocator)
	copy(cpath, path)
	fd := open(cstring(raw_data(cpath)), O_RDONLY | O_CLOEXEC)
	if fd < 0 do return nil, false
	defer close(fd)
	out := make([dynamic]u8, 0, 64 * 1024, allocator)
	buf: [16384]u8
	for {
		n := read(fd, &buf[0], len(buf))
		if n < 0 && errno() == EINTR do continue
		if n <= 0 do break
		append(&out, ..buf[:n])
	}
	return out[:], true
}

write_file :: proc(path: string, data: []u8) -> bool {
	cpath := make([]u8, len(path) + 1, context.temp_allocator)
	copy(cpath, path)
	fd := open(cstring(raw_data(cpath)), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, c.int(0o600))
	if fd < 0 do return false
	defer close(fd)
	off := 0
	for off < len(data) {
		n := write(fd, &data[off], c.size_t(len(data)) - c.size_t(off))
		if n < 0 && errno() == EINTR do continue
		if n <= 0 do return false
		off += int(n)
	}
	return true
}

// --- lifecycle --------------------------------------------------------------

on_start :: proc "c" (a: ^ANativeActivity) {}
on_stop :: proc "c" (a: ^ANativeActivity) {}

on_resume :: proc "c" (a: ^ANativeActivity) {
	context = g_ctx
	plat.resumed = true
	app_on_resume()
	request_redraw(0)
}

on_pause :: proc "c" (a: ^ANativeActivity) {
	context = g_ctx
	plat.resumed = false
	app_save_settings()
}

on_destroy :: proc "c" (a: ^ANativeActivity) {
	context = g_ctx
	if plat.timer_fd > 0 {
		ALooper_removeFd(plat.looper, plat.timer_fd)
		close(plat.timer_fd)
		plat.timer_fd = -1
	}
	app_on_destroy()
	shutdown_gl()
	plat.activity = nil
}

on_focus :: proc "c" (a: ^ANativeActivity, has_focus: c.int) {
	context = g_ctx
	request_redraw(0)
}

on_config_changed :: proc "c" (a: ^ANativeActivity) {
	context = g_ctx
	update_density()
	request_redraw(0)
}

on_content_rect :: proc "c" (a: ^ANativeActivity, r: ^ARect) {
	context = g_ctx
	plat.content = r^
	plat.have_content = true
	request_redraw(0)
}

// --- window / GL ------------------------------------------------------------

on_window_created :: proc "c" (a: ^ANativeActivity, window: rawptr) {
	context = g_ctx
	plat.window = window
	if !gfx_init(&plat.gfx, window) {
		log_info("EGL init failed")
		gfx_destroy(&plat.gfx)
		return
	}
	renderer_init(&rend)
	atlas_reset() // force full re-upload into the fresh context
	atlas_gpu_init()
	plat.gl_ready = true
	frame()
}

on_window_resized :: proc "c" (a: ^ANativeActivity, window: rawptr) {
	context = g_ctx
	request_redraw(0)
}

on_window_redraw :: proc "c" (a: ^ANativeActivity, window: rawptr) {
	context = g_ctx
	frame()
}

on_window_destroyed :: proc "c" (a: ^ANativeActivity, window: rawptr) {
	context = g_ctx
	shutdown_gl()
	plat.window = nil
}

shutdown_gl :: proc() {
	if plat.gl_ready || plat.gfx.display != nil {
		gfx_destroy(&plat.gfx)
	}
	plat.gl_ready = false
}

// --- timer-driven redraw ------------------------------------------------------

request_redraw :: proc(delay_ms: f64) {
	if plat.timer_fd <= 0 do return
	due := now_ms() + max(delay_ms, 0)
	if plat.timer_due != 0 && plat.timer_due <= due do return
	plat.timer_due = due
	d := max(delay_ms, 0.05)
	spec := itimerspec{}
	spec.it_value.tv_sec = i64(d / 1000)
	spec.it_value.tv_nsec = i64(math.mod(d, 1000) * 1e6)
	if spec.it_value.tv_sec == 0 && spec.it_value.tv_nsec == 0 do spec.it_value.tv_nsec = 50_000
	timerfd_settime(plat.timer_fd, 0, &spec, nil)
}

on_timer :: proc "c" (fd: c.int, events: c.int, data: rawptr) -> c.int {
	context = g_ctx
	buf: u64
	read(fd, &buf, 8)
	plat.timer_due = 0
	frame()
	return 1
}

frame :: proc() {
	defer free_all(context.temp_allocator)
	app_tick()
	if !plat.gl_ready || plat.window == nil {
		ui_end_frame()
		return
	}
	gfx_query_size(&plat.gfx)
	w, h := f32(plat.gfx.width), f32(plat.gfx.height)
	if w <= 0 || h <= 0 do return

	// usable area (excludes status bar / IME when the window is resized for it)
	area := Rect{0, 0, w, h}
	if plat.have_content {
		cr := plat.content
		area = Rect{f32(cr.left), f32(cr.top), f32(cr.right - cr.left), f32(cr.bottom - cr.top)}
		if area.w <= 0 || area.h <= 0 do area = Rect{0, 0, w, h}
	}

	ui.animating = false
	clear(&ui.scrolls)
	ui_update_pointer()
	renderer_begin(&rend, w, h, COL_BG)
	app_draw(area)
	renderer_flush(&rend)
	eglSwapBuffers(plat.gfx.display, plat.gfx.surface)
	ui.last_frame_t = now_ms()
	ui_end_frame()
	if ui.animating do request_redraw(0)
}

// --- input ------------------------------------------------------------------

on_input_created :: proc "c" (a: ^ANativeActivity, queue: rawptr) {
	context = g_ctx
	plat.queue = queue
	AInputQueue_attachLooper(queue, plat.looper, 1, on_input, nil)
}

on_input_destroyed :: proc "c" (a: ^ANativeActivity, queue: rawptr) {
	context = g_ctx
	AInputQueue_detachLooper(queue)
	plat.queue = nil
}

on_input :: proc "c" (fd: c.int, events: c.int, data: rawptr) -> c.int {
	context = g_ctx
	q := plat.queue
	if q == nil do return 1
	ev: rawptr
	any_event := false
	for AInputQueue_getEvent(q, &ev) >= 0 {
		if AInputQueue_preDispatchEvent(q, ev) != 0 do continue
		handled := handle_input(ev)
		AInputQueue_finishEvent(q, ev, handled ? 1 : 0)
		any_event = true
	}
	if any_event do request_redraw(0)
	return 1
}

handle_input :: proc(ev: rawptr) -> bool {
	switch AInputEvent_getType(ev) {
	case AINPUT_EVENT_TYPE_MOTION:
		action := AMotionEvent_getAction(ev)
		x := AMotionEvent_getX(ev, 0)
		y := AMotionEvent_getY(ev, 0)
		switch action & AMOTION_EVENT_ACTION_MASK {
		case AMOTION_EVENT_ACTION_DOWN:
			ui_pointer_down(x, y)
		case AMOTION_EVENT_ACTION_MOVE:
			ui_pointer_move(x, y)
		case AMOTION_EVENT_ACTION_UP:
			ui_pointer_up(x, y, false)
		case AMOTION_EVENT_ACTION_CANCEL:
			ui_pointer_up(x, y, true)
		case AMOTION_EVENT_ACTION_SCROLL:
			v := AMotionEvent_getAxisValue(ev, AMOTION_EVENT_AXIS_VSCROLL, 0)
			for s in ui.scrolls {
				if rect_contains(s.view, x, y) do s.offset -= v * 48 * ui.dp
			}
		}
		return true
	case AINPUT_EVENT_TYPE_KEY:
		action := AKeyEvent_getAction(ev)
		code := AKeyEvent_getKeyCode(ev)
		meta := AKeyEvent_getMetaState(ev)
		if code == AKEYCODE_BACK {
			if action == AKEY_EVENT_ACTION_UP do return app_back()
			return app_can_go_back()
		}
		if action != AKEY_EVENT_ACTION_DOWN do return action == AKEY_EVENT_ACTION_UP && ui.focus != nil
		ctrl := meta & AMETA_CTRL_ON != 0
		switch code {
		case AKEYCODE_DEL:
			append(&ui.keys, Key.Backspace)
		case AKEYCODE_FORWARD_DEL:
			append(&ui.keys, Key.Delete)
		case AKEYCODE_ENTER, AKEYCODE_NUMPAD_ENTER:
			if ctrl do app_hotkey_send()
			else do append(&ui.keys, Key.Enter)
		case AKEYCODE_DPAD_LEFT:
			append(&ui.keys, Key.Left)
		case AKEYCODE_DPAD_RIGHT:
			append(&ui.keys, Key.Right)
		case AKEYCODE_DPAD_UP:
			append(&ui.keys, Key.Up)
		case AKEYCODE_DPAD_DOWN:
			append(&ui.keys, Key.Down)
		case AKEYCODE_MOVE_HOME:
			append(&ui.keys, Key.Home)
		case AKEYCODE_MOVE_END:
			append(&ui.keys, Key.End)
		case AKEYCODE_ESCAPE:
			tf_blur()
		case:
			if ctrl && code == 50 { // KEYCODE_V
				append(&ui.keys, Key.Paste)
				return true
			}
			if ui.focus == nil do return false
			r := key_to_unicode(plat.activity.env, AInputEvent_getDeviceId(ev), code, meta)
			if r <= 0 do return false
			b, n := utf8_encode_rune(r)
			append(&ui.text_input, ..b[:n])
		}
		return true
	}
	return false
}

utf8_encode_rune :: proc(r: rune) -> ([4]u8, int) {
	b: [4]u8
	c := u32(r)
	switch {
	case c < 0x80:
		b[0] = u8(c)
		return b, 1
	case c < 0x800:
		b[0] = u8(0xC0 | (c >> 6)); b[1] = u8(0x80 | (c & 0x3F))
		return b, 2
	case c < 0x10000:
		b[0] = u8(0xE0 | (c >> 12)); b[1] = u8(0x80 | ((c >> 6) & 0x3F)); b[2] = u8(0x80 | (c & 0x3F))
		return b, 3
	case:
		b[0] = u8(0xF0 | (c >> 18)); b[1] = u8(0x80 | ((c >> 12) & 0x3F)); b[2] = u8(0x80 | ((c >> 6) & 0x3F)); b[3] = u8(0x80 | (c & 0x3F))
		return b, 4
	}
}

// --- platform services used by the UI -------------------------------------------

plat_show_keyboard :: proc(show: bool) {
	if plat.activity == nil do return
	if show == ui.keyboard_visible && !show do return
	ui.keyboard_visible = show
	soft_keyboard(plat.activity.env, plat.activity.clazz, show)
	if show do ANativeActivity_showSoftInput(plat.activity, ANATIVEACTIVITY_SHOW_SOFT_INPUT_IMPLICIT)
	else do ANativeActivity_hideSoftInput(plat.activity, 0)
}

plat_clipboard_get :: proc() -> string {
	if plat.activity == nil do return ""
	return clipboard_get(plat.activity.env, plat.activity.clazz, context.temp_allocator)
}

plat_clipboard_set :: proc(s: string) {
	if plat.activity == nil do return
	clipboard_set(plat.activity.env, plat.activity.clazz, s)
}

plat_finish :: proc() {
	if plat.activity != nil do ANativeActivity_finish(plat.activity)
}

// Watch a socket fd on the main looper.
plat_watch_fd :: proc(fd: c.int, want_write: bool) {
	ev: c.int = ALOOPER_EVENT_INPUT
	if want_write do ev |= ALOOPER_EVENT_OUTPUT
	ALooper_addFd(plat.looper, fd, -2, ev, on_socket, nil)
}

plat_unwatch_fd :: proc(fd: c.int) {
	ALooper_removeFd(plat.looper, fd)
}

on_socket :: proc "c" (fd: c.int, events: c.int, data: rawptr) -> c.int {
	context = g_ctx
	keep := net_on_ready(fd, events)
	request_redraw(0)
	return keep ? 1 : 0
}

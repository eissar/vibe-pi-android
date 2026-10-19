package main

// SDL3 platform layer + Clay renderer. SDL's SDLActivity (Java, shipped by
// SDL) loads libmain.so and calls SDL_main on its own thread.

import "base:runtime"
import "core:c"
import "core:math"
import "core:strings"
import clay "clay"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

Platform :: struct {
	window:   ^sdl.Window,
	renderer: ^sdl.Renderer,
	engine:   ^ttf.TextEngine,
	data_dir: string,
	w, h:     f32,
	dirty:    bool,
	active_until: f64, // keep rendering until this time (scroll momentum etc.)
}

plat: Platform

FONT_SANS :: 0
FONT_MONO :: 1
FONT_BOLD :: 2
FONT_PATHS := [3][]cstring {
	{"/system/fonts/Roboto-Regular.ttf", "/system/fonts/DroidSans.ttf"},
	{"/system/fonts/DroidSansMono.ttf", "/system/fonts/CutiveMono.ttf"},
	{"/system/fonts/Roboto-Bold.ttf", "/system/fonts/Roboto-Medium.ttf", "/system/fonts/Roboto-Regular.ttf"},
}
FALLBACK_FONTS := []cstring{"/system/fonts/NotoColorEmoji.ttf", "/system/fonts/NotoSansSymbols-Regular-Subsetted.ttf", "/system/fonts/NotoSansCJK-Regular.ttc"}

fonts: map[[2]int]^ttf.Font
fallbacks: [dynamic]^ttf.Font

get_font :: proc(id: int, size: int) -> ^ttf.Font {
	key := [2]int{id, size}
	if f, ok := fonts[key]; ok do return f
	f: ^ttf.Font
	for p in FONT_PATHS[id] {
		f = ttf.OpenFont(p, f32(size))
		if f != nil do break
	}
	if f != nil {
		for p in FALLBACK_FONTS {
			fb := ttf.OpenFont(p, f32(size))
			if fb != nil {
				ttf.AddFallbackFont(f, fb)
				append(&fallbacks, fb)
			}
		}
	}
	fonts[key] = f
	return f
}

measure_text :: proc "c" (text: clay.StringSlice, config: ^clay.TextElementConfig, _: rawptr) -> clay.Dimensions {
	context = g_ctx
	f := get_font(int(config.fontId), int(config.fontSize))
	if f == nil do return {}
	w, h: c.int
	if text.length > 0 do ttf.GetStringSize(f, cstring(text.chars), c.size_t(text.length), &w, &h)
	else do h = ttf.GetFontHeight(f)
	return {f32(w), f32(h)}
}

// Cache of shaped TTF_Text objects, evicted when unused for a frame.
Text_Key :: struct {
	s:    string,
	font: [2]int,
}
Text_Entry :: struct {
	text:  ^ttf.Text,
	frame: int,
}
text_cache: map[Text_Key]Text_Entry
frame_no: int

draw_text_cmd :: proc(r: clay.BoundingBox, t: clay.TextRenderData) {
	s := string(t.stringContents.chars[:t.stringContents.length])
	key := Text_Key{s, {int(t.fontId), int(t.fontSize)}}
	e, ok := text_cache[key]
	if !ok {
		f := get_font(key.font[0], key.font[1])
		if f == nil do return
		key.s = strings.clone(s)
		e.text = ttf.CreateText(plat.engine, f, cstring(raw_data(key.s)), c.size_t(len(key.s)))
	}
	e.frame = frame_no
	text_cache[key] = e
	col := t.textColor
	ttf.SetTextColor(e.text, u8(col.r), u8(col.g), u8(col.b), u8(col.a))
	ttf.DrawRendererText(e.text, r.x, r.y)
}

evict_text_cache :: proc() {
	stale := make([dynamic]Text_Key, 0, 64, context.temp_allocator)
	for k, e in text_cache do if e.frame < frame_no - 1 do append(&stale, k)
	for k in stale {
		ttf.DestroyText(text_cache[k].text)
		delete_key(&text_cache, k)
		delete(k.s)
	}
}

// --- geometry ---------------------------------------------------------------

verts: [dynamic]sdl.Vertex
idx: [dynamic]c.int

fcol :: proc(c: clay.Color) -> sdl.FColor {return {c.r / 255, c.g / 255, c.b / 255, c.a / 255}}

tri :: proc(a, b, cc: [2]f32, col: clay.Color) {
	fc := fcol(col)
	base := c.int(len(verts))
	append(&verts, sdl.Vertex{position = sdl.FPoint(a), color = fc}, sdl.Vertex{position = sdl.FPoint(b), color = fc}, sdl.Vertex{position = sdl.FPoint(cc), color = fc})
	append(&idx, base, base + 1, base + 2)
}

fill_rect :: proc(x, y, w, h: f32, col: clay.Color) {
	tri({x, y}, {x + w, y}, {x + w, y + h}, col)
	tri({x, y}, {x + w, y + h}, {x, y + h}, col)
}

fill_rrect :: proc(r: clay.BoundingBox, radius: f32, col: clay.Color) {
	rad := min(radius, r.width / 2, r.height / 2)
	if rad < 1 {
		fill_rect(r.x, r.y, r.width, r.height, col)
		return
	}
	fill_rect(r.x + rad, r.y, r.width - 2 * rad, r.height, col)
	fill_rect(r.x, r.y + rad, rad, r.height - 2 * rad, col)
	fill_rect(r.x + r.width - rad, r.y + rad, rad, r.height - 2 * rad, col)
	N :: 8
	centers := [4][2]f32{{r.x + rad, r.y + rad}, {r.x + r.width - rad, r.y + rad}, {r.x + r.width - rad, r.y + r.height - rad}, {r.x + rad, r.y + r.height - rad}}
	for cpt, q in centers {
		a0 := math.PI + f32(q) * math.PI / 2
		for i in 0 ..< N {
			a := a0 + f32(i) / N * math.PI / 2
			b := a0 + f32(i + 1) / N * math.PI / 2
			tri(cpt, cpt + {math.cos(a), math.sin(a)} * rad, cpt + {math.cos(b), math.sin(b)} * rad, col)
		}
	}
}

seg :: proc(a, b: [2]f32, thick: f32, col: clay.Color) {
	d := b - a
	l := math.sqrt(d.x * d.x + d.y * d.y)
	if l < 0.001 do return
	n := [2]f32{-d.y, d.x} / l * (thick / 2)
	tri(a + n, b + n, b - n, col)
	tri(a + n, b - n, a - n, col)
}

flush_geometry :: proc() {
	if len(idx) == 0 do return
	sdl.RenderGeometry(plat.renderer, nil, raw_data(verts), c.int(len(verts)), raw_data(idx), c.int(len(idx)))
	clear(&verts)
	clear(&idx)
}

render :: proc(cmds: ^clay.ClayArray(clay.RenderCommand)) {
	sdl.SetRenderDrawColor(plat.renderer, u8(COL_BG.r), u8(COL_BG.g), u8(COL_BG.b), 255)
	sdl.RenderClear(plat.renderer)
	clips := make([dynamic]sdl.Rect, 0, 8, context.temp_allocator)
	for i in 0 ..< cmds.length {
		cmd := clay.RenderCommandArray_Get(cmds, i)
		b := cmd.boundingBox
		#partial switch cmd.commandType {
		case .Rectangle:
			rd := cmd.renderData.rectangle
			fill_rrect(b, rd.cornerRadius.topLeft, rd.backgroundColor)
		case .Border:
			bd := cmd.renderData.border
			w := bd.width
			if w.top > 0 do fill_rect(b.x, b.y, b.width, f32(w.top), bd.color)
			if w.bottom > 0 do fill_rect(b.x, b.y + b.height - f32(w.bottom), b.width, f32(w.bottom), bd.color)
			if w.left > 0 do fill_rect(b.x, b.y, f32(w.left), b.height, bd.color)
			if w.right > 0 do fill_rect(b.x + b.width - f32(w.right), b.y, f32(w.right), b.height, bd.color)
		case .Text:
			flush_geometry()
			draw_text_cmd(b, cmd.renderData.text)
		case .Custom:
			draw_icon(b, cast(^Icon)cmd.renderData.custom.customData)
		case .ScissorStart:
			flush_geometry()
			r := sdl.Rect{c.int(b.x), c.int(b.y), c.int(math.ceil(b.width)), c.int(math.ceil(b.height))}
			if len(clips) > 0 {
				p := clips[len(clips) - 1]
				x0, y0 := max(r.x, p.x), max(r.y, p.y)
				x1, y1 := min(r.x + r.w, p.x + p.w), min(r.y + r.h, p.y + p.h)
				r = {x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
			}
			append(&clips, r)
			sdl.SetRenderClipRect(plat.renderer, &clips[len(clips) - 1])
		case .ScissorEnd:
			flush_geometry()
			pop(&clips)
			if len(clips) > 0 do sdl.SetRenderClipRect(plat.renderer, &clips[len(clips) - 1])
			else do sdl.SetRenderClipRect(plat.renderer, nil)
		}
	}
	flush_geometry()
	sdl.RenderPresent(plat.renderer)
}

// --- files / time ----------------------------------------------------------

read_file :: proc(path: string, allocator := context.allocator) -> ([]u8, bool) {
	n: uint
	p := sdl.LoadFile(strings.clone_to_cstring(path, context.temp_allocator), &n)
	if p == nil do return nil, false
	defer sdl.free(p)
	out := make([]u8, int(n), allocator)
	copy(out, ([^]u8)(p)[:n])
	return out, true
}

write_file :: proc(path: string, data: []u8) -> bool {
	return sdl.SaveFile(strings.clone_to_cstring(path, context.temp_allocator), raw_data(data), uint(len(data)))
}

now_ms :: proc "contextless" () -> f64 {return f64(sdl.GetTicksNS()) / 1e6}

plat_clipboard_get :: proc() -> string {
	p := sdl.GetClipboardText()
	if p == nil do return ""
	defer sdl.free(p)
	return strings.clone(string(cstring(p)), context.temp_allocator)
}

plat_clipboard_set :: proc(s: string) {
	sdl.SetClipboardText(strings.clone_to_cstring(s, context.temp_allocator))
}

plat_show_keyboard :: proc(show: bool) {
	if show do _ = sdl.StartTextInput(plat.window)
	else do _ = sdl.StopTextInput(plat.window)
}

// --- main loop ----------------------------------------------------------------

g_ctx: runtime.Context

clay_error :: proc "c" (e: clay.ErrorData) {
	context = g_ctx
	sdl.Log("clay: %.*s", e.errorText.length, e.errorText.chars)
}

@(export, link_name = "SDL_main")
sdl_main :: proc "c" (argc: c.int, argv: [^]cstring) -> c.int {
	context = runtime.default_context()
	g_ctx = context

	sdl.SetHint(sdl.HINT_ANDROID_TRAP_BACK_BUTTON, "1")
	sdl.SetHint(sdl.HINT_TOUCH_MOUSE_EVENTS, "0") // we read fingers directly
	if !sdl.Init(sdl.INIT_VIDEO) || !ttf.Init() {
		sdl.Log("init failed: %s", sdl.GetError())
		return 1
	}
	plat.window = sdl.CreateWindow("Pi Agent", 0, 0, {.FULLSCREEN, .RESIZABLE, .HIGH_PIXEL_DENSITY})
	plat.renderer = sdl.CreateRenderer(plat.window, nil)
	sdl.SetRenderVSync(plat.renderer, 1)
	plat.engine = ttf.CreateRendererTextEngine(plat.renderer)
	plat.data_dir = strings.clone(string(sdl.GetAndroidInternalStoragePath()))

	clay.SetMaxElementCount(65536)
	mem_size := clay.MinMemorySize()
	arena := clay.CreateArenaWithCapacityAndMemory(uint(mem_size), raw_data(make([]u8, mem_size)))
	clay.Initialize(arena, {1, 1}, {handler = clay_error})
	clay.SetMeasureTextFunction(measure_text, nil)

	app_init()
	plat.dirty = true
	last := now_ms()
	running := true
	for running {
		ev: sdl.Event
		wait: i32 = (plat.dirty || now_ms() < plat.active_until) ? 0 : 50
		if sdl.WaitEventTimeout(&ev, wait) {
			running = handle_event(&ev)
			for running && sdl.PollEvent(&ev) do running = handle_event(&ev)
		}
		for _ in 0 ..< 64 {
			if !net_pump(0) do break
			plat.dirty = true
		}
		app_tick()
		t := now_ms()
		if plat.dirty || t < plat.active_until {
			plat.dirty = false
			frame(f32(min(t - last, 100) / 1000))
			last = t
		} else {
			last = t
		}
		free_all(context.temp_allocator)
	}
	app_save_settings()
	return 0
}

frame :: proc(dt: f32) {
	w, h: c.int
	sdl.GetRenderOutputSize(plat.renderer, &w, &h)
	plat.w, plat.h = f32(w), f32(h)
	ui.dp = max(sdl.GetWindowDisplayScale(plat.window), 1)

	clay.SetLayoutDimensions({plat.w, plat.h})
	clay.SetPointerState({ui.px, ui.py}, ui.down && !ui.long_fired)
	clay.UpdateScrollContainers(true, {0, ui.wheel * 60 * ui.dp}, dt)
	ui.wheel = 0
	ui_update()

	clay.BeginLayout()
	safe: sdl.Rect
	sdl.GetWindowSafeArea(plat.window, &safe)
	app_layout(safe)
	cmds := clay.EndLayout(dt)
	app_after_layout()

	frame_no += 1
	render(&cmds)
	evict_text_cache()
	ui_end_frame()
	if ui.animating do plat.active_until = max(plat.active_until, now_ms() + 32)
}

handle_event :: proc(ev: ^sdl.Event) -> bool {
	plat.dirty = true
	#partial switch ev.type {
	case .QUIT, .TERMINATING:
		return false
	case .FINGER_DOWN:
		ui_pointer_down(ev.tfinger.x * plat.w, ev.tfinger.y * plat.h)
	case .FINGER_MOTION:
		ui_pointer_move(ev.tfinger.x * plat.w, ev.tfinger.y * plat.h)
	case .FINGER_UP:
		ui_pointer_up(ev.tfinger.x * plat.w, ev.tfinger.y * plat.h, false)
	case .FINGER_CANCELED:
		ui_pointer_up(ui.px, ui.py, true)
	case .MOUSE_BUTTON_DOWN:
		if ev.button.which != sdl.TOUCH_MOUSEID do ui_pointer_down(ev.button.x * px_scale(), ev.button.y * px_scale())
	case .MOUSE_MOTION:
		if ev.motion.which != sdl.TOUCH_MOUSEID {
			ui.px, ui.py = ev.motion.x * px_scale(), ev.motion.y * px_scale()
			if ui.down do ui_pointer_move(ui.px, ui.py)
		}
	case .MOUSE_BUTTON_UP:
		if ev.button.which != sdl.TOUCH_MOUSEID do ui_pointer_up(ev.button.x * px_scale(), ev.button.y * px_scale(), false)
	case .MOUSE_WHEEL:
		ui.wheel += ev.wheel.y
	case .TEXT_INPUT:
		append(&ui.text_input, string(ev.text.text))
	case .KEY_DOWN:
		k := ev.key.key
		ctrl := ev.key.mod & sdl.KMOD_CTRL != {}
		switch k {
		case sdl.K_AC_BACK:
			if !app_back() do sdl.SendAndroidBackButton()
		case sdl.K_BACKSPACE:
			append(&ui.keys, Key.Backspace)
		case sdl.K_DELETE:
			append(&ui.keys, Key.Delete)
		case sdl.K_RETURN, sdl.K_KP_ENTER:
			if ctrl do app_hotkey_send()
			else do append(&ui.keys, Key.Enter)
		case sdl.K_LEFT:
			append(&ui.keys, Key.Left)
		case sdl.K_RIGHT:
			append(&ui.keys, Key.Right)
		case sdl.K_HOME:
			append(&ui.keys, Key.Home)
		case sdl.K_END:
			append(&ui.keys, Key.End)
		case sdl.K_ESCAPE:
			tf_blur()
		case sdl.K_V:
			if ctrl do append(&ui.keys, Key.Paste)
		}
	case .DID_ENTER_FOREGROUND:
		app_on_resume()
	case .WILL_ENTER_BACKGROUND:
		app_save_settings()
	}
	return true
}

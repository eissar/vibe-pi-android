package main

// Input state + small widget helpers on top of Clay.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import clay "clay"
import sdl "vendor:sdl3"

Color :: clay.Color

COL_BG       :: Color{15, 17, 21, 255}
COL_PANEL    :: Color{23, 26, 33, 255}
COL_CARD     :: Color{30, 34, 43, 255}
COL_CARD_HI  :: Color{40, 45, 57, 255}
COL_BORDER   :: Color{48, 54, 68, 255}
COL_TEXT     :: Color{230, 232, 238, 255}
COL_DIM      :: Color{139, 147, 167, 255}
COL_FAINT    :: Color{95, 102, 120, 255}
COL_ACCENT   :: Color{124, 156, 255, 255}
COL_USER     :: Color{43, 53, 80, 255}
COL_ERROR    :: Color{255, 107, 107, 255}
COL_ERR_BG   :: Color{60, 24, 28, 255}
COL_OK       :: Color{80, 200, 120, 255}
COL_WARN     :: Color{240, 180, 80, 255}
COL_CODE_BG  :: Color{12, 14, 18, 255}
COL_THINK    :: Color{154, 163, 181, 255}
COL_SHADE    :: Color{0, 0, 0, 170}

Key :: enum {
	Backspace,
	Delete,
	Enter,
	Left,
	Right,
	Home,
	End,
	Paste,
}

UI :: struct {
	dp:             f32,
	down:           bool,
	down_x, down_y: f32,
	px, py:         f32,
	down_time:      f64,
	dragging:       bool,
	long_fired:     bool,
	wheel:          f32,
	tap:            bool,
	long_press:     bool,
	text_input:     [dynamic]u8,
	keys:           [dynamic]Key,
	focus:          ^Text_Field,
	focus_seen:     bool,
	focus_miss:     int,
	animating:      bool,
	modal:          bool, // an overlay is open: underlying widgets ignore taps
}

ui: UI

LONG_PRESS_MS :: 450

px_scale :: proc() -> f32 {return sdl.GetWindowPixelDensity(plat.window)}

ui_pointer_down :: proc(x, y: f32) {
	ui.down = true
	ui.down_x, ui.down_y, ui.px, ui.py = x, y, x, y
	ui.down_time = now_ms()
	ui.dragging = false
	ui.long_fired = false
}

ui_pointer_move :: proc(x, y: f32) {
	ui.px, ui.py = x, y
	if ui.down && !ui.dragging && (abs(x - ui.down_x) > 8 * ui.dp || abs(y - ui.down_y) > 8 * ui.dp) do ui.dragging = true
}

ui_pointer_up :: proc(x, y: f32, cancel: bool) {
	if !ui.down do return
	ui.down = false
	ui.px, ui.py = x, y
	if !cancel && !ui.dragging && !ui.long_fired do ui.tap = true
	plat.active_until = now_ms() + 1500 // let Clay's scroll momentum play out
}

ui_update :: proc() {
	if ui.down && !ui.dragging && !ui.long_fired {
		if now_ms() - ui.down_time >= LONG_PRESS_MS {
			ui.long_fired = true
			ui.long_press = true
		} else {
			ui.animating = true
		}
	}
}

ui_end_frame :: proc() {
	ui.tap = false
	ui.long_press = false
	clear(&ui.text_input)
	clear(&ui.keys)
	ui.focus_miss = ui.focus_seen ? 0 : ui.focus_miss + 1
	if ui.focus_miss > 2 && ui.focus != nil do tf_blur()
	ui.focus_seen = false
	ui.animating = false
}

// --- interaction queries (use the previous frame's layout) ---------------------------

clicked :: proc(id: clay.ElementId) -> bool {
	if ui.tap && !ui.modal && clay.PointerOver(id) {
		ui.tap = false
		return true
	}
	return false
}

long_pressed :: proc(id: clay.ElementId) -> bool {
	if ui.long_press && !ui.modal && clay.PointerOver(id) {
		ui.long_press = false
		return true
	}
	return false
}

pressed :: proc(id: clay.ElementId) -> bool {
	return ui.down && !ui.dragging && !ui.modal && clay.PointerOver(id)
}

// --- element helpers -----------------------------------------------------------------

dpx :: proc(v: f32) -> f32 {return math.round(v * ui.dp)}
dpu :: proc(v: f32) -> u16 {return u16(math.round(v * ui.dp))}
pad :: proc(x, y: f32) -> clay.Padding {return {dpu(x), dpu(x), dpu(y), dpu(y)}}
radius :: proc(r: f32) -> clay.CornerRadius {return clay.CornerRadiusAll(dpx(r))}
grow :: clay.SizingGrow
fit :: clay.SizingFit
fixed :: proc(v: f32) -> clay.SizingAxis {return clay.SizingFixed(dpx(v))}

text :: proc(s: string, size: f32 = 15, col := COL_TEXT, font := FONT_SANS, wrap := clay.TextWrapMode.Words) {
	clay.TextDynamic(s, {fontId = u16(font), fontSize = dpu(size), textColor = col, wrapMode = wrap})
}

// Single line, clipped to the available width.
text_line :: proc(s: string, size: f32, col: Color, font := FONT_SANS) {
	line := s
	if i := strings.index_byte(line, '\n'); i >= 0 do line = line[:i]
	if clay.UI()({layout = {sizing = {grow(), fit()}}, clip = {horizontal = true}}) {
		text(line, size, col, font, .None)
	}
}

hover_col :: proc(id: clay.ElementId, base, hi: Color) -> Color {
	return pressed(id) ? hi : base
}

button :: proc(id: string, label: string, bg := COL_ACCENT, fg := COL_BG, enabled := true, width: Maybe(clay.SizingAxis) = nil) -> bool {
	eid := clay.ID(id)
	w := width.? or_else grow()
	col := enabled ? hover_col(eid, bg, lighten(bg)) : Color{bg.r, bg.g, bg.b, 90}
	if clay.UI(eid)({
		layout = {sizing = {w, fixed(46)}, childAlignment = {.Center, .Center}, padding = pad(16, 0)},
		backgroundColor = col,
		cornerRadius = radius(10),
	}) {
		text(label, 15, enabled ? fg : Color{fg.r, fg.g, fg.b, 140}, FONT_BOLD, .None)
	}
	return enabled && clicked(eid)
}

lighten :: proc(c: Color) -> Color {return {min(c.r + 28, 255), min(c.g + 28, 255), min(c.b + 28, 255), c.a}}

// --- vector icons (Clay custom elements) ---------------------------------------------

Icon_Kind :: enum {
	Back,
	Plus,
	Refresh,
	Send,
	Stop,
	Chevron_Right,
	Chevron_Down,
	Dot,
	Spinner,
}

Icon :: struct {
	kind: Icon_Kind,
	col:  Color,
}

icon :: proc(kind: Icon_Kind, size: f32, col: Color) {
	ic := new(Icon, context.temp_allocator)
	ic^ = {kind, col}
	if kind == .Spinner do ui.animating = true
	if clay.UI()({layout = {sizing = {fixed(size), fixed(size)}}, custom = {customData = ic}}) {}
}

icon_button :: proc(id: string, kind: Icon_Kind, col := COL_TEXT) -> bool {
	eid := clay.ID(id)
	if clay.UI(eid)({
		layout = {sizing = {fixed(48), fixed(48)}, childAlignment = {.Center, .Center}},
		backgroundColor = pressed(eid) ? COL_CARD_HI : {},
		cornerRadius = radius(24),
	}) {
		icon(kind, 18, col)
	}
	return clicked(eid)
}

draw_icon :: proc(b: clay.BoundingBox, ic: ^Icon) {
	s := min(b.width, b.height)
	cx, cy := b.x + b.width / 2, b.y + b.height / 2
	t := max(2, s * 0.12)
	col := ic.col
	switch ic.kind {
	case .Back:
		seg({cx + s * 0.2, cy - s * 0.4}, {cx - s * 0.2, cy}, t, col)
		seg({cx - s * 0.2, cy}, {cx + s * 0.2, cy + s * 0.4}, t, col)
	case .Chevron_Right:
		seg({cx - s * 0.15, cy - s * 0.3}, {cx + s * 0.15, cy}, t * 0.8, col)
		seg({cx + s * 0.15, cy}, {cx - s * 0.15, cy + s * 0.3}, t * 0.8, col)
	case .Chevron_Down:
		seg({cx - s * 0.3, cy - s * 0.15}, {cx, cy + s * 0.15}, t * 0.8, col)
		seg({cx, cy + s * 0.15}, {cx + s * 0.3, cy - s * 0.15}, t * 0.8, col)
	case .Plus:
		seg({cx - s / 2, cy}, {cx + s / 2, cy}, t, col)
		seg({cx, cy - s / 2}, {cx, cy + s / 2}, t, col)
	case .Refresh:
		N :: 14
		prev: [2]f32
		for i in 0 ..= N {
			a := f32(0.35) + f32(i) / N * (2 * math.PI - 0.9)
			p := [2]f32{cx + math.cos(a) * s / 2, cy + math.sin(a) * s / 2}
			if i > 0 do seg(prev, p, t, col)
			prev = p
		}
		tip := [2]f32{cx + math.cos(f32(0.35)) * s / 2, cy + math.sin(f32(0.35)) * s / 2}
		tri(tip + {-s * 0.3, -s * 0.05}, tip + {s * 0.15, -s * 0.3}, tip + {s * 0.12, s * 0.12}, col)
	case .Send:
		tri({cx - s * 0.45, cy - s * 0.45}, {cx + s * 0.5, cy}, {cx - s * 0.2, cy}, col)
		tri({cx - s * 0.45, cy + s * 0.45}, {cx + s * 0.5, cy}, {cx - s * 0.2, cy}, col)
	case .Stop:
		fill_rrect({cx - s * 0.35, cy - s * 0.35, s * 0.7, s * 0.7}, s * 0.1, col)
	case .Dot:
		fill_rrect({cx - s * 0.3, cy - s * 0.3, s * 0.6, s * 0.6}, s * 0.3, col)
	case .Spinner:
		tm := f32(now_ms() / 1000)
		for i in 0 ..< 8 {
			a := f32(i) / 8 * 2 * math.PI + tm * 4
			p := [2]f32{cx + math.cos(a) * s * 0.4, cy + math.sin(a) * s * 0.4}
			d := s * 0.16
			fill_rrect({p.x - d / 2, p.y - d / 2, d, d}, d / 2, {col.r, col.g, col.b, 60 + f32(i) * 24})
		}
	}
}

// --- text fields ------------------------------------------------------------------------

Text_Field :: struct {
	buf:       [dynamic]u8,
	cursor:    int,
	multiline: bool,
	secret:    bool,
}

tf_text :: proc(t: ^Text_Field) -> string {return string(t.buf[:])}

tf_set :: proc(t: ^Text_Field, s: string) {
	clear(&t.buf)
	append(&t.buf, s)
	t.cursor = len(t.buf)
}

tf_insert :: proc(t: ^Text_Field, s: string) {
	t.cursor = clamp(t.cursor, 0, len(t.buf))
	inject_at(&t.buf, t.cursor, s)
	t.cursor += len(s)
}

tf_focus :: proc(t: ^Text_Field) {
	ui.focus = t
	ui.focus_seen = true
	plat_show_keyboard(true)
}

tf_blur :: proc() {
	if ui.focus != nil {
		ui.focus = nil
		plat_show_keyboard(false)
	}
}

@(private = "file")
rune_back :: proc(b: []u8, i: int) -> int {
	j := i - 1
	for j > 0 && (b[j] & 0xC0) == 0x80 do j -= 1
	return max(j, 0)
}

// Edits a focused field from this frame's input; draws it. Returns true on Enter in single-line fields.
text_field :: proc(id: string, t: ^Text_Field, placeholder: string, size: f32 = 16, max_h: f32 = 48) -> (submitted: bool) {
	eid := clay.ID(id)
	focused := ui.focus == t
	if focused {
		ui.focus_seen = true
		if len(ui.text_input) > 0 {
			s := string(ui.text_input[:])
			if !t.multiline {
				s, _ = strings.replace_all(s, "\n", "", context.temp_allocator)
			}
			tf_insert(t, s)
		}
		for k in ui.keys {
			switch k {
			case .Backspace:
				if t.cursor > 0 {
					p := rune_back(t.buf[:], t.cursor)
					remove_range(&t.buf, p, t.cursor)
					t.cursor = p
				}
			case .Delete:
				if t.cursor < len(t.buf) {
					_, n := utf8.decode_rune(t.buf[t.cursor:])
					remove_range(&t.buf, t.cursor, t.cursor + n)
				}
			case .Left:
				if t.cursor > 0 do t.cursor = rune_back(t.buf[:], t.cursor)
			case .Right:
				if t.cursor < len(t.buf) {
					_, n := utf8.decode_rune(t.buf[t.cursor:])
					t.cursor += n
				}
			case .Home:
				t.cursor = 0
			case .End:
				t.cursor = len(t.buf)
			case .Paste:
				tf_insert(t, plat_clipboard_get())
			case .Enter:
				if t.multiline do tf_insert(t, "\n")
				else do submitted = true
			}
		}
		// keep the IME from covering the field
		if d := clay.GetElementData(eid); d.found {
			r := sdl.Rect{i32(d.boundingBox.x / px_scale()), i32(d.boundingBox.y / px_scale()), i32(d.boundingBox.width / px_scale()), i32(d.boundingBox.height / px_scale())}
			_ = sdl.SetTextInputArea(plat.window, &r, 0)
		}
	}
	if ui.tap && clay.PointerOver(eid) {
		ui.tap = false
		tf_focus(t)
		t.cursor = len(t.buf)
		focused = true
	}
	if ui.long_press && clay.PointerOver(eid) {
		ui.long_press = false
		tf_focus(t)
		if clip := plat_clipboard_get(); len(clip) > 0 {
			tf_insert(t, clip)
			toast("Pasted from clipboard")
		}
		focused = true
	}

	shown := tf_text(t)
	if t.secret do shown = strings.repeat("•", utf8.rune_count(shown), context.temp_allocator)
	else if focused do shown = fmt.tprintf("%s│%s", shown[:t.cursor], shown[t.cursor:])
	if clay.UI(eid)({
		layout = {sizing = {grow(), fit({min = dpx(46), max = dpx(max_h)})}, padding = pad(12, 12)},
		backgroundColor = COL_CARD,
		cornerRadius = radius(10),
		border = {color = focused ? COL_ACCENT : COL_BORDER, width = {1, 1, 1, 1, 0}},
		clip = {vertical = true, childOffset = {0, 0}},
	}) {
		if len(t.buf) == 0 && !focused do text(placeholder, size, COL_FAINT)
		else if len(t.buf) == 0 do text("│", size, COL_ACCENT)
		else do text(shown, size, COL_TEXT, FONT_SANS, t.multiline ? .Words : .None)
	}
	return
}

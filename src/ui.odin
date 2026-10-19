package main

// Small immediate-mode UI toolkit on top of the batched renderer:
// taps, long-press, kinetic scrolling, buttons, and text fields.

import "core:math"
import "core:unicode/utf8"

// Theme ----------------------------------------------------------------------

COL_BG       :: Color{15, 17, 21, 255}
COL_PANEL    :: Color{23, 26, 33, 255}
COL_CARD     :: Color{30, 34, 43, 255}
COL_CARD_HI  :: Color{40, 45, 57, 255}
COL_BORDER   :: Color{48, 54, 68, 255}
COL_TEXT     :: Color{230, 232, 238, 255}
COL_DIM      :: Color{139, 147, 167, 255}
COL_FAINT    :: Color{95, 102, 120, 255}
COL_ACCENT   :: Color{124, 156, 255, 255}
COL_ACCENT_D :: Color{70, 92, 170, 255}
COL_USER     :: Color{43, 53, 80, 255}
COL_ERROR    :: Color{255, 107, 107, 255}
COL_OK       :: Color{80, 200, 120, 255}
COL_WARN     :: Color{240, 180, 80, 255}
COL_CODE_BG  :: Color{12, 14, 18, 255}
COL_THINK    :: Color{154, 163, 181, 255}

with_alpha :: proc(c: Color, a: u8) -> Color {return {c.r, c.g, c.b, a}}

// Input state -----------------------------------------------------------------

Key :: enum {
	None,
	Backspace,
	Delete,
	Enter,
	Left,
	Right,
	Up,
	Down,
	Home,
	End,
	Paste,
	Select_All,
}

Scroll :: struct {
	offset:    f32,
	velocity:  f32,
	content_h: f32,
	view:      Rect,
	dragged:   bool,
}

UI :: struct {
	dp:            f32,
	// pointer
	down:          bool,
	down_x, down_y: f32,
	px, py:        f32,
	down_time:     f64,
	dragging:      bool,
	long_fired:    bool,
	drag_scroll:   ^Scroll,
	last_move_t:   f64,
	vel_y:         f32,
	// per-frame events (consumed by widgets)
	tap:           bool,
	tap_x, tap_y:  f32,
	long_press:    bool,
	lp_x, lp_y:    f32,
	// keyboard
	text_input:    [dynamic]u8,
	keys:          [dynamic]Key,
	focus:         ^Text_Field,
	focus_seen:    bool, // focused field was drawn this frame
	// scroll views registered in the last frame
	scrolls:       [dynamic]^Scroll,
	animating:     bool,
	last_frame_t:  f64,
	keyboard_visible: bool,
}

ui: UI

LONG_PRESS_MS :: 450

ui_pointer_down :: proc(x, y: f32) {
	ui.down = true
	ui.down_x, ui.down_y = x, y
	ui.px, ui.py = x, y
	ui.down_time = now_ms()
	ui.last_move_t = ui.down_time
	ui.dragging = false
	ui.long_fired = false
	ui.vel_y = 0
	ui.drag_scroll = nil
	// stop any fling under the finger
	for s in ui.scrolls {
		if rect_contains(s.view, x, y) {
			s.velocity = 0
			ui.drag_scroll = s
		}
	}
}

ui_pointer_move :: proc(x, y: f32) {
	if !ui.down do return
	dy := y - ui.py
	t := now_ms()
	if !ui.dragging {
		slop := 8 * ui.dp
		if abs(x - ui.down_x) > slop || abs(y - ui.down_y) > slop {
			ui.dragging = true
			dy = y - ui.down_y
		}
	}
	if ui.dragging && ui.drag_scroll != nil && !ui.long_fired {
		s := ui.drag_scroll
		s.offset -= dy
		s.dragged = true
		dt := f32(max(t - ui.last_move_t, 1))
		inst := -dy / dt // px per ms
		ui.vel_y = ui.vel_y * 0.4 + inst * 0.6
	}
	ui.px, ui.py = x, y
	ui.last_move_t = t
}

ui_pointer_up :: proc(x, y: f32, cancel: bool) {
	if !ui.down do return
	ui.down = false
	if cancel do return
	if !ui.dragging && !ui.long_fired {
		ui.tap = true
		ui.tap_x, ui.tap_y = x, y
	} else if ui.dragging && ui.drag_scroll != nil {
		// fling unless finger rested before release
		if now_ms() - ui.last_move_t < 80 {
			ui.drag_scroll.velocity = clamp(ui.vel_y, -8 * ui.dp, 8 * ui.dp)
		}
	}
	ui.dragging = false
}

// Called every frame: long press detection.
ui_update_pointer :: proc() {
	if ui.down && !ui.dragging && !ui.long_fired {
		if now_ms() - ui.down_time >= LONG_PRESS_MS {
			ui.long_fired = true
			ui.long_press = true
			ui.lp_x, ui.lp_y = ui.down_x, ui.down_y
		} else {
			ui.animating = true // keep ticking until long-press threshold
		}
	}
}

ui_end_frame :: proc() {
	ui.tap = false
	ui.long_press = false
	clear(&ui.text_input)
	clear(&ui.keys)
	if !ui.focus_seen do ui.focus = nil
	ui.focus_seen = false
}

// Widgets -----------------------------------------------------------------------

// Returns true when tapped. Draws pressed feedback.
ui_tap :: proc(r: Rect) -> bool {
	if ui.tap && rect_contains(r, ui.tap_x, ui.tap_y) && rect_contains(rend.clip, ui.tap_x, ui.tap_y) {
		ui.tap = false
		return true
	}
	return false
}

ui_long_press :: proc(r: Rect) -> bool {
	if ui.long_press && rect_contains(r, ui.lp_x, ui.lp_y) && rect_contains(rend.clip, ui.lp_x, ui.lp_y) {
		ui.long_press = false
		return true
	}
	return false
}

ui_pressed :: proc(r: Rect) -> bool {
	return ui.down && !ui.dragging && rect_contains(r, ui.down_x, ui.down_y) && rect_contains(r, ui.px, ui.py)
}

button :: proc(r: Rect, label: string, bg: Color = COL_ACCENT, fg: Color = COL_BG, enabled := true) -> bool {
	col := bg
	if !enabled do col = with_alpha(bg, 90)
	else if ui_pressed(r) do col = Color{u8(min(int(bg.r) + 30, 255)), u8(min(int(bg.g) + 30, 255)), u8(min(int(bg.b) + 30, 255)), bg.a}
	draw_rrect(&rend, r, 10 * ui.dp, col)
	size := 15 * ui.dp
	tw := measure_text(FONT_BOLD, size, label)
	lh := font_line_height(FONT_BOLD, size)
	draw_text(&rend, FONT_BOLD, size, math.round(r.x + (r.w - tw) / 2), math.round(r.y + (r.h - lh) / 2), label, enabled ? fg : with_alpha(fg, 140))
	return enabled && ui_tap(r)
}

// Icon button with a custom draw callback area; returns tapped.
icon_button :: proc(r: Rect) -> bool {
	if ui_pressed(r) do draw_rrect(&rend, r, r.h / 2, COL_CARD_HI)
	return ui_tap(r)
}

// Triangle (filled) using the white texel.
tri :: proc(a, b, c: [2]f32, col: Color) {
	u, v := atlas.white_u, atlas.white_v
	append(&rend.verts, Vertex{a.x, a.y, u, v, col}, Vertex{b.x, b.y, u, v, col}, Vertex{c.x, c.y, u, v, col})
}

// Thick line segment as a quad.
seg :: proc(a, b: [2]f32, thick: f32, col: Color) {
	d := b - a
	l := math.sqrt(d.x * d.x + d.y * d.y)
	if l < 0.001 do return
	n := [2]f32{-d.y, d.x} / l * (thick / 2)
	tri(a + n, b + n, b - n, col)
	tri(a + n, b - n, a - n, col)
}

icon_chevron_left :: proc(cx, cy, s: f32, col: Color) {
	t := 2.2 * ui.dp
	seg({cx + s * 0.25, cy - s * 0.5}, {cx - s * 0.25, cy}, t, col)
	seg({cx - s * 0.25, cy}, {cx + s * 0.25, cy + s * 0.5}, t, col)
}

icon_chevron :: proc(cx, cy, s: f32, open: bool, col: Color) {
	t := 1.8 * ui.dp
	if open {
		seg({cx - s * 0.5, cy - s * 0.25}, {cx, cy + s * 0.25}, t, col)
		seg({cx, cy + s * 0.25}, {cx + s * 0.5, cy - s * 0.25}, t, col)
	} else {
		seg({cx - s * 0.25, cy - s * 0.5}, {cx + s * 0.25, cy}, t, col)
		seg({cx + s * 0.25, cy}, {cx - s * 0.25, cy + s * 0.5}, t, col)
	}
}

icon_plus :: proc(cx, cy, s: f32, col: Color) {
	t := 2.2 * ui.dp
	seg({cx - s / 2, cy}, {cx + s / 2, cy}, t, col)
	seg({cx, cy - s / 2}, {cx, cy + s / 2}, t, col)
}

icon_refresh :: proc(cx, cy, s: f32, col: Color) {
	t := 2 * ui.dp
	rad := s / 2
	N :: 14
	prev: [2]f32
	for i in 0 ..= N {
		a := f32(0.35) + f32(i) / N * (2 * math.PI - 0.9)
		p := [2]f32{cx + math.cos(a) * rad, cy + math.sin(a) * rad}
		if i > 0 do seg(prev, p, t, col)
		prev = p
	}
	// arrow head at the start of the arc
	a0 := f32(0.35)
	tip := [2]f32{cx + math.cos(a0) * rad, cy + math.sin(a0) * rad}
	tri(tip + {-s * 0.3, -s * 0.05}, tip + {s * 0.15, -s * 0.3}, tip + {s * 0.12, s * 0.12}, col)
}

icon_send :: proc(cx, cy, s: f32, col: Color) {
	tri({cx - s * 0.45, cy - s * 0.45}, {cx + s * 0.5, cy}, {cx - s * 0.45, cy + s * 0.45}, col)
	tri({cx - s * 0.45, cy - s * 0.45}, {cx - s * 0.1, cy}, {cx - s * 0.45, cy + s * 0.45}, COL_ACCENT)
}

icon_stop :: proc(cx, cy, s: f32, col: Color) {
	draw_rrect(&rend, {cx - s / 2, cy - s / 2, s, s}, 2 * ui.dp, col)
}

icon_dots :: proc(cx, cy, s: f32, col: Color) {
	d := s * 0.22
	for i in -1 ..= 1 {
		draw_rrect(&rend, {cx - d / 2, cy + f32(i) * s * 0.35 - d / 2, d, d}, d / 2, col)
	}
}

spinner :: proc(cx, cy, s: f32, col: Color) {
	t := f32(now_ms() / 1000)
	for i in 0 ..< 8 {
		a := f32(i) / 8 * 2 * math.PI + t * 4
		alpha := u8(60 + (i * 195) / 8)
		p := [2]f32{cx + math.cos(a) * s / 2, cy + math.sin(a) * s / 2}
		d := s * 0.18
		draw_rrect(&rend, {p.x - d / 2, p.y - d / 2, d, d}, d / 2, with_alpha(col, alpha))
	}
	ui.animating = true
}

// Scrolling ---------------------------------------------------------------------

scroll_begin :: proc(s: ^Scroll, view: Rect) {
	s.view = view
	append(&ui.scrolls, s)
	push_clip(&rend, view)
}

// content_h: total height of content drawn; clamps & applies fling.
scroll_end :: proc(s: ^Scroll, content_h: f32) {
	pop_clip(&rend)
	s.content_h = content_h
	max_off := max(0, content_h - s.view.h)
	if s.velocity != 0 && !ui.down {
		dt := f32(clamp(now_ms() - ui.last_frame_t, 1, 50))
		s.offset += s.velocity * dt
		s.velocity *= math.pow(f32(0.996), dt)
		if abs(s.velocity) < 0.02 do s.velocity = 0
		ui.animating = true
	}
	if s.offset < 0 {
		s.offset = 0
		s.velocity = 0
	}
	if s.offset > max_off {
		s.offset = max_off
		s.velocity = 0
	}
	// scrollbar
	if content_h > s.view.h + 1 {
		frac := s.view.h / content_h
		bar_h := max(24 * ui.dp, s.view.h * frac)
		bar_y := s.view.y + (s.view.h - bar_h) * (s.offset / max_off)
		draw_rrect(&rend, {s.view.x + s.view.w - 4 * ui.dp, bar_y, 3 * ui.dp, bar_h}, 1.5 * ui.dp, with_alpha(COL_DIM, 90))
	}
}

scroll_at_bottom :: proc(s: ^Scroll) -> bool {
	return s.offset >= s.content_h - s.view.h - 4 * ui.dp
}

// Text fields -----------------------------------------------------------------------

Text_Field :: struct {
	buf:       [dynamic]u8,
	cursor:    int,
	multiline: bool,
	secret:    bool,
	scroll_y:  f32,
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

@(private = "file")
prev_rune_start :: proc(b: []u8, i: int) -> int {
	j := i - 1
	for j > 0 && (b[j] & 0xC0) == 0x80 do j -= 1
	return max(j, 0)
}
@(private = "file")
next_rune_end :: proc(b: []u8, i: int) -> int {
	if i >= len(b) do return len(b)
	_, n := utf8.decode_rune(b[i:])
	return i + n
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

// Processes input if focused, then draws. Returns true if Enter was pressed on a single-line field.
text_field :: proc(t: ^Text_Field, r: Rect, placeholder: string, size: f32, max_lines := 1) -> (submitted: bool) {
	focused := ui.focus == t
	if focused {
		ui.focus_seen = true
		if len(ui.text_input) > 0 {
			s := string(ui.text_input[:])
			if !t.multiline {
				// strip newlines in single-line fields
				tmp := make([dynamic]u8, 0, len(s), context.temp_allocator)
				for ch in s {
					if ch == '\n' || ch == '\r' do continue
					b, n := utf8.encode_rune(ch)
					append(&tmp, ..b[:n])
				}
				s = string(tmp[:])
			}
			tf_insert(t, s)
		}
		for k in ui.keys {
			switch k {
			case .Backspace:
				if t.cursor > 0 {
					p := prev_rune_start(t.buf[:], t.cursor)
					remove_range(&t.buf, p, t.cursor)
					t.cursor = p
				}
			case .Delete:
				if t.cursor < len(t.buf) {
					n := next_rune_end(t.buf[:], t.cursor)
					remove_range(&t.buf, t.cursor, n)
				}
			case .Left:
				if t.cursor > 0 do t.cursor = prev_rune_start(t.buf[:], t.cursor)
			case .Right:
				t.cursor = next_rune_end(t.buf[:], t.cursor)
			case .Home:
				t.cursor = 0
			case .End:
				t.cursor = len(t.buf)
			case .Up, .Down, .None, .Select_All:
			case .Paste:
				clip := plat_clipboard_get()
				if len(clip) > 0 do tf_insert(t, clip)
			case .Enter:
				if t.multiline do tf_insert(t, "\n")
				else do submitted = true
			}
		}
	}

	draw_rrect(&rend, r, 10 * ui.dp, focused ? COL_BORDER : COL_CARD)
	inner := Rect{r.x + 1.5 * ui.dp, r.y + 1.5 * ui.dp, r.w - 3 * ui.dp, r.h - 3 * ui.dp}
	draw_rrect(&rend, inner, 9 * ui.dp, COL_CARD)
	pad := 12 * ui.dp
	text_r := Rect{r.x + pad, r.y + pad * 0.75, r.w - pad * 2, r.h - pad * 1.5}
	lh := font_line_height(FONT_SANS, size)

	if ui_tap(r) {
		if !focused do tf_focus(t)
		else do plat_show_keyboard(true)
		t.cursor = len(t.buf)
		focused = true
	}
	if ui_long_press(r) {
		tf_focus(t)
		clip := plat_clipboard_get()
		if len(clip) > 0 {
			tf_insert(t, clip)
			toast("Pasted from clipboard")
		}
		focused = true
	}

	text := tf_text(t)
	display := text
	if t.secret {
		dots := make([]u8, len(text), context.temp_allocator)
		for &d in dots do d = '*'
		display = string(dots)
	}
	push_clip(&rend, text_r)
	defer pop_clip(&rend)
	if len(text) == 0 {
		draw_text(&rend, FONT_SANS, size, text_r.x, text_r.y, placeholder, COL_FAINT)
		if focused do draw_rect(&rend, {text_r.x, text_r.y, 2 * ui.dp, lh}, COL_ACCENT)
		return
	}
	if t.multiline {
		lines := make([dynamic]Line, 0, 16, context.temp_allocator)
		wrap_text(FONT_SANS, size, display, text_r.w - 4 * ui.dp, &lines)
		// find caret line
		caret_line := len(lines) - 1
		for l, i in lines {
			if t.cursor >= l.start && t.cursor <= l.end {caret_line = i; break}
		}
		visible := max(1, int(text_r.h / lh))
		first := max(0, min(caret_line - visible + 1, len(lines) - visible))
		first = max(first, 0)
		y := text_r.y
		for i in first ..< len(lines) {
			l := lines[i]
			draw_text(&rend, FONT_SANS, size, text_r.x, y, display[l.start:l.end], COL_TEXT)
			if focused && i == caret_line {
				cx := text_r.x + measure_text(FONT_SANS, size, display[l.start:t.cursor])
				draw_rect(&rend, {cx, y, 2 * ui.dp, lh}, COL_ACCENT)
			}
			y += lh
		}
	} else {
		cw := measure_text(FONT_SANS, size, display[:t.cursor])
		shift := max(0, cw - (text_r.w - 4 * ui.dp))
		draw_text(&rend, FONT_SANS, size, text_r.x - shift, text_r.y, display, COL_TEXT)
		if focused do draw_rect(&rend, {text_r.x - shift + cw, text_r.y, 2 * ui.dp, lh}, COL_ACCENT)
	}
	return
}

// Height a multiline field wants for its content (clamped to max_lines).
text_field_height :: proc(t: ^Text_Field, w: f32, size: f32, max_lines: int) -> f32 {
	pad := 12 * ui.dp
	lh := font_line_height(FONT_SANS, size)
	lines := make([dynamic]Line, 0, 16, context.temp_allocator)
	if len(t.buf) > 0 do wrap_text(FONT_SANS, size, tf_text(t), w - pad * 2 - 4 * ui.dp, &lines)
	n := clamp(len(lines), 1, max_lines)
	return f32(n) * lh + pad * 1.5
}

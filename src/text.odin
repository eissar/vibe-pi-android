package main

import "core:math"
import "core:unicode/utf8"

TAB_SPACES :: 4

draw_text :: proc(r: ^Renderer, font_id: int, size: f32, x, y: f32, text: string, col: Color) -> f32 {
	size := math.round(size)
	baseline := math.round(y + font_ascent(font_id, size))
	pen := x
	space_adv := get_glyph(font_id, ' ', size).advance
	clip := r.clip
	for ch in text {
		if ch == '\t' {
			pen += space_adv * TAB_SPACES
			continue
		}
		if ch == '\n' || ch == '\r' do continue
		g := get_glyph(font_id, ch, size)
		if g.valid && pen < clip.x + clip.w {
			gx := math.round(pen + g.xoff)
			gy := baseline + g.yoff
			quad(r, gx, gy, gx + g.w, gy + g.h, g.u0, g.v0, g.u1, g.v1, col)
		}
		pen += g.advance
	}
	return pen - x
}

measure_text :: proc(font_id: int, size: f32, text: string) -> f32 {
	size := math.round(size)
	w: f32 = 0
	for ch in text {
		if ch == '\t' {
			w += get_glyph(font_id, ' ', size).advance * TAB_SPACES
			continue
		}
		if ch == '\n' || ch == '\r' do continue
		w += get_glyph(font_id, ch, size).advance
	}
	return w
}

// Truncate with an ellipsis to fit max_w.
fit_text :: proc(font_id: int, size: f32, text: string, max_w: f32) -> string {
	if measure_text(font_id, size, text) <= max_w do return text
	ell :: "…"
	ew := measure_text(font_id, size, ell)
	size := math.round(size)
	w: f32 = 0
	for ch, i in text {
		adv := get_glyph(font_id, ch, size).advance
		if w + adv + ew > max_w {
			return concat(text[:i], ell)
		}
		w += adv
	}
	return text
}

concat :: proc(a, b: string, allocator := context.temp_allocator) -> string {
	buf := make([]u8, len(a) + len(b), allocator)
	copy(buf, a)
	copy(buf[len(a):], b)
	return string(buf)
}

Line :: struct {
	start, end: int, // byte offsets into the source text
}

// Greedy word wrap. Honors '\n'. Appends to `out`.
wrap_text :: proc(font_id: int, size: f32, text: string, max_w: f32, out: ^[dynamic]Line) {
	size := math.round(size)
	max_w := max(max_w, 10)
	space_adv := get_glyph(font_id, ' ', size).advance
	line_start := 0
	w: f32 = 0
	last_break := -1 // byte index where the next line would start after a space
	w_at_break: f32 = 0
	i := 0
	for i < len(text) {
		ch, n := utf8.decode_rune_in_string(text[i:])
		if ch == '\n' {
			append(out, Line{line_start, i})
			i += n
			line_start = i
			w = 0
			last_break = -1
			continue
		}
		adv: f32
		if ch == '\t' do adv = space_adv * TAB_SPACES
		else if ch == '\r' do adv = 0
		else do adv = get_glyph(font_id, ch, size).advance
		if w + adv > max_w && i > line_start {
			if ch == ' ' {
				// break at this space, swallow it
				append(out, Line{line_start, i})
				i += n
				line_start = i
				w = 0
				last_break = -1
				continue
			}
			if last_break > line_start {
				append(out, Line{line_start, last_break - 1})
				line_start = last_break
				w = w - w_at_break
				last_break = -1
			} else {
				append(out, Line{line_start, i})
				line_start = i
				w = 0
				last_break = -1
			}
		}
		w += adv
		i += n
		if ch == ' ' {
			last_break = i
			w_at_break = w
		}
	}
	append(out, Line{line_start, len(text)})
}

// Byte offset in `text` closest to pixel x.
text_index_at :: proc(font_id: int, size: f32, text: string, x: f32) -> int {
	size := math.round(size)
	w: f32 = 0
	for ch, i in text {
		adv := get_glyph(font_id, ch, size).advance
		if ch == '\t' do adv = get_glyph(font_id, ' ', size).advance * TAB_SPACES
		if w + adv / 2 > x do return i
		w += adv
	}
	return len(text)
}

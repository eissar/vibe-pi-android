package main

// Layout + drawing of the chat transcript (bubbles, markdown-ish text,
// code blocks, collapsible thinking and tool cards).

import "core:fmt"
import "core:math"
import "core:strings"

Item_Kind :: enum {
	Bubble,
	Text,
	Code,
	Heading,
	Think,
	Tool,
	Error,
	Label,
}

Item :: struct {
	kind:        Item_Kind,
	text:        string,
	lines:       [dynamic]Line,
	font:        int,
	size:        f32,
	color:       Color,
	x, y, w, h:  f32,
	key:         string,
	expanded:    bool,
	tool_status: int, // 0 unknown, 1 running, 2 ok, 3 error
	title:       string,
	subtitle:    string,
	// tool cards: two bodies (input / output)
	out_text:    string,
	out_lines:   [dynamic]Line,
	out_font:    int,
}

MAX_TOOL_CHARS :: 12000

layout_clear :: proc(m: ^Message) {
	for &it in m.items {
		delete(it.lines)
		delete(it.out_lines)
	}
	clear(&m.items)
	for s in m.layout_strs do delete(s)
	clear(&m.layout_strs)
}

@(private = "file")
lown :: proc(m: ^Message, s: string) -> string {
	c := strings.clone(s)
	append(&m.layout_strs, c)
	return c
}

@(private = "file")
clip_text :: proc(m: ^Message, s: string, limit: int) -> string {
	if len(s) <= limit do return s
	cut := limit
	for cut > 0 && (s[cut] & 0xC0) == 0x80 do cut -= 1
	return lown(m, fmt.tprintf("%s\n… (%d more characters)", s[:cut], len(s) - cut))
}

S_BODY :: 15
S_CODE :: 13
S_SMALL :: 12.5
S_HEAD :: 17

// Splits markdown-ish text into paragraphs / code blocks / headings.
@(private = "file")
layout_markdown :: proc(m: ^Message, text: string, w: f32, y: ^f32) {
	dp := ui.dp
	para := strings.builder_make(context.temp_allocator)
	code := strings.builder_make(context.temp_allocator)
	in_code := false

	flush_para :: proc(m: ^Message, para: ^strings.Builder, w: f32, y: ^f32) {
		s := strings.trim_right(strings.to_string(para^), "\n ")
		if len(strings.trim_space(s)) > 0 {
			it := Item{kind = .Text, font = FONT_SANS, size = S_BODY * ui.dp, color = COL_TEXT}
			it.text = lown(m, s)
			wrap_text(it.font, it.size, it.text, w, &it.lines)
			it.x, it.y, it.w = 0, y^, w
			it.h = f32(len(it.lines)) * font_line_height(it.font, it.size)
			append(&m.items, it)
			y^ += it.h + 6 * ui.dp
		}
		strings.builder_reset(para)
	}

	rest := text
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_left_space(line)
		if strings.has_prefix(trimmed, "```") {
			if !in_code {
				flush_para(m, &para, w, y)
				in_code = true
				strings.builder_reset(&code)
			} else {
				in_code = false
				it := Item{kind = .Code, font = FONT_MONO, size = S_CODE * dp, color = COL_TEXT}
				it.text = lown(m, strings.trim_right(strings.to_string(code), "\n"))
				pad := 10 * dp
				wrap_text(it.font, it.size, it.text, w - pad * 2, &it.lines)
				it.x, it.y, it.w = 0, y^, w
				it.h = f32(len(it.lines)) * font_line_height(it.font, it.size) + pad * 2
				append(&m.items, it)
				y^ += it.h + 6 * dp
			}
			continue
		}
		if in_code {
			strings.write_string(&code, line)
			strings.write_byte(&code, '\n')
			continue
		}
		if strings.has_prefix(trimmed, "#") {
			level := 0
			for level < len(trimmed) && trimmed[level] == '#' do level += 1
			if level <= 6 && level < len(trimmed) && trimmed[level] == ' ' {
				flush_para(m, &para, w, y)
				it := Item{kind = .Heading, font = FONT_BOLD, size = (level <= 2 ? S_HEAD : S_BODY + 0.5) * dp, color = COL_TEXT}
				it.text = lown(m, strip_inline(trimmed[level + 1:]))
				wrap_text(it.font, it.size, it.text, w, &it.lines)
				it.x, it.y, it.w = 0, y^ + 2 * dp, w
				it.h = f32(len(it.lines)) * font_line_height(it.font, it.size)
				append(&m.items, it)
				y^ += it.h + 8 * dp
				continue
			}
		}
		l := line
		if strings.has_prefix(trimmed, "- ") || strings.has_prefix(trimmed, "* ") {
			indent := len(line) - len(trimmed)
			l = concat(concat(line[:indent], "• "), trimmed[2:])
		}
		strings.write_string(&para, strip_inline(l))
		strings.write_byte(&para, '\n')
	}
	if in_code {
		// unterminated fence (still streaming): show what we have as code
		it := Item{kind = .Code, font = FONT_MONO, size = S_CODE * dp, color = COL_TEXT}
		it.text = lown(m, strings.trim_right(strings.to_string(code), "\n"))
		pad := 10 * dp
		wrap_text(it.font, it.size, it.text, w - pad * 2, &it.lines)
		it.x, it.y, it.w = 0, y^, w
		it.h = f32(len(it.lines)) * font_line_height(it.font, it.size) + pad * 2
		append(&m.items, it)
		y^ += it.h + 6 * dp
	}
	flush_para(m, &para, w, y)
}

// Removes **bold** / __bold__ markers (we have no inline styling).
strip_inline :: proc(s: string) -> string {
	if !strings.contains(s, "**") && !strings.contains(s, "__") do return s
	out, _ := strings.replace_all(s, "**", "", context.temp_allocator)
	out2, _ := strings.replace_all(out, "__", "", context.temp_allocator)
	return out2
}

// Builds the layout of one message for a given content width.
layout_message :: proc(m: ^Message, index: int, w: f32) {
	layout_clear(m)
	m.layout_w = w
	m.dirty = false
	dp := ui.dp
	y: f32 = 0

	switch m.role {
	case .User:
		text := message_plain_text(m)
		it := Item{kind = .Bubble, font = FONT_SANS, size = S_BODY * dp, color = COL_TEXT}
		it.text = lown(m, strings.trim_space(text))
		pad := 12 * dp
		max_w := w * 0.85
		wrap_text(it.font, it.size, it.text, max_w - pad * 2, &it.lines)
		widest: f32 = 0
		for l in it.lines do widest = max(widest, measure_text(it.font, it.size, it.text[l.start:l.end]))
		it.w = min(max_w, widest + pad * 2 + 1)
		it.h = f32(len(it.lines)) * font_line_height(it.font, it.size) + pad * 1.6
		it.x = w - it.w
		it.y = 0
		append(&m.items, it)
		y = it.h

	case .Assistant, .Custom, .Other:
		if m.role != .Assistant && len(m.label) > 0 {
			it := Item{kind = .Label, font = FONT_SANS, size = S_SMALL * dp, color = COL_FAINT, text = m.label}
			it.y = y
			it.w = w
			it.h = font_line_height(it.font, it.size)
			append(&m.items, it)
			y += it.h + 2 * dp
		}
		for blk, bi in m.blocks {
			switch blk.kind {
			case .Text:
				layout_markdown(m, blk.text, w, &y)
			case .Thinking:
				key := lown(m, fmt.tprintf("think:%d:%d", index, bi))
				it := Item{kind = .Think, font = FONT_SANS, size = S_CODE * dp, color = COL_THINK, key = key}
				it.expanded = app.expanded[key]
				first := strings.trim_space(blk.text)
				if i := strings.index_byte(first, '\n'); i >= 0 do first = first[:i]
				it.title = lown(m, strip_inline(first))
				head_h := 34 * dp
				it.x, it.y, it.w = 0, y, w
				it.h = head_h
				if it.expanded {
					it.text = lown(m, strings.trim_space(blk.text))
					wrap_text(it.font, it.size, it.text, w - 24 * dp, &it.lines)
					it.h += f32(len(it.lines)) * font_line_height(it.font, it.size) + 10 * dp
				}
				append(&m.items, it)
				y += it.h + 6 * dp
			case .Tool_Call:
				layout_tool(m, blk.name, blk.summary, blk.call_id, blk.text, w, &y)
			case .Image:
				it := Item{kind = .Label, font = FONT_SANS, size = S_SMALL * dp, color = COL_DIM, text = "[image]"}
				it.y, it.w, it.h = y, w, font_line_height(FONT_SANS, S_SMALL * dp)
				append(&m.items, it)
				y += it.h + 6 * dp
			case .Error:
				it := Item{kind = .Error, font = FONT_SANS, size = S_CODE * dp, color = COL_ERROR}
				it.text = blk.text
				pad := 10 * dp
				wrap_text(it.font, it.size, it.text, w - pad * 2, &it.lines)
				it.x, it.y, it.w = 0, y, w
				it.h = f32(len(it.lines)) * font_line_height(it.font, it.size) + pad * 2
				append(&m.items, it)
				y += it.h + 6 * dp
			}
		}
		if y > 0 do y -= 6 * dp

	case .Tool_Result:
		// Rendered inside the matching tool call card when there is one.
		if _, has_call := app.chat.calls[m.tool_call_id]; has_call {
			m.height = 0
			return
		}
		out := message_plain_text(m)
		layout_tool(m, len(m.tool_name) > 0 ? m.tool_name : "tool result", "", m.tool_call_id, "", w, &y, out, true)
		if y > 0 do y -= 6 * dp
	}
	m.height = y
}

@(private = "file")
layout_tool :: proc(m: ^Message, name, summary, call_id, args: string, w: f32, y: ^f32, orphan_output := "", orphan := false) {
	dp := ui.dp
	key := lown(m, concat("tool:", call_id))
	it := Item{kind = .Tool, key = key, font = FONT_MONO, size = S_CODE * dp, color = COL_TEXT, out_font = FONT_MONO}
	it.title = name
	it.subtitle = summary
	it.expanded = app.expanded[key]
	result: ^Message
	if !orphan {
		if r, ok := app.chat.results[call_id]; ok do result = r
	}
	switch {
	case app.chat.running_tools[call_id]:
		it.tool_status = 1
	case orphan:
		it.tool_status = m.is_error ? 3 : 2
	case result != nil:
		it.tool_status = result.is_error ? 3 : 2
	}
	head_h := 40 * dp
	it.x, it.y, it.w = 0, y^, w
	it.h = head_h
	if it.expanded {
		pad := 12 * dp
		inner := w - pad * 2
		lh := font_line_height(FONT_MONO, it.size)
		label_h := font_line_height(FONT_SANS, S_SMALL * dp) + 4 * dp
		if len(args) > 0 {
			it.text = clip_text(m, args, MAX_TOOL_CHARS)
			wrap_text(FONT_MONO, it.size, it.text, inner, &it.lines)
			it.h += label_h + f32(len(it.lines)) * lh + 8 * dp
		}
		out := orphan ? orphan_output : (result != nil ? message_plain_text(result) : "")
		if len(out) == 0 && it.tool_status == 1 do out = "(running…)"
		if len(out) > 0 {
			it.out_text = clip_text(m, out, MAX_TOOL_CHARS)
			if it.out_text == out do it.out_text = lown(m, out)
			wrap_text(FONT_MONO, it.size, it.out_text, inner, &it.out_lines)
			it.h += label_h + f32(len(it.out_lines)) * lh + 8 * dp
		}
		it.h += 4 * dp
	}
	append(&m.items, it)
	y^ += it.h + 6 * dp
}

// Draws a message whose top-left is (x, y). Returns nothing; handles taps.
draw_message :: proc(m: ^Message, x, y: f32) {
	dp := ui.dp
	for &it in m.items {
		r := Rect{x + it.x, y + it.y, it.w, it.h}
		if r.y > rend.clip.y + rend.clip.h || r.y + r.h < rend.clip.y do continue
		lh := font_line_height(it.font, it.size)
		switch it.kind {
		case .Bubble:
			draw_rrect(&rend, r, 14 * dp, COL_USER)
			pad := 12 * dp
			ty := r.y + pad * 0.8
			for l in it.lines {
				draw_text(&rend, it.font, it.size, r.x + pad, ty, it.text[l.start:l.end], it.color)
				ty += lh
			}
		case .Text, .Heading:
			ty := r.y
			for l in it.lines {
				if ty + lh >= rend.clip.y && ty <= rend.clip.y + rend.clip.h {
					draw_text(&rend, it.font, it.size, r.x, ty, it.text[l.start:l.end], it.color)
				}
				ty += lh
			}
		case .Code, .Error:
			pad := 10 * dp
			draw_rrect(&rend, r, 8 * dp, it.kind == .Code ? COL_CODE_BG : Color{60, 24, 28, 255})
			ty := r.y + pad
			for l in it.lines {
				if ty + lh >= rend.clip.y && ty <= rend.clip.y + rend.clip.h {
					draw_text(&rend, it.font, it.size, r.x + pad, ty, it.text[l.start:l.end], it.color)
				}
				ty += lh
			}
		case .Label:
			draw_text(&rend, it.font, it.size, r.x, r.y, it.text, it.color)
		case .Think:
			head := Rect{r.x, r.y, r.w, 34 * dp}
			if ui_pressed(head) do draw_rrect(&rend, head, 8 * dp, COL_CARD)
			icon_chevron(r.x + 9 * dp, head.y + head.h / 2, 8 * dp, it.expanded, COL_FAINT)
			hs := S_SMALL * dp
			label := "Thinking"
			lw := draw_text(&rend, FONT_BOLD, hs, r.x + 22 * dp, head.y + (head.h - font_line_height(FONT_BOLD, hs)) / 2, label, COL_FAINT)
			if !it.expanded && len(it.title) > 0 {
				tx := r.x + 22 * dp + lw + 8 * dp
				draw_text(&rend, FONT_SANS, hs, tx, head.y + (head.h - font_line_height(FONT_SANS, hs)) / 2, fit_text(FONT_SANS, hs, it.title, r.x + r.w - tx), COL_FAINT)
			}
			if ui_tap(head) {
				toggle_expanded(it.key)
				m.dirty = true
			}
			if it.expanded {
				draw_rect(&rend, {r.x + 9 * dp, head.y + head.h, 2 * dp, r.h - head.h - 6 * dp}, COL_BORDER)
				ty := head.y + head.h
				for l in it.lines {
					if ty + lh >= rend.clip.y && ty <= rend.clip.y + rend.clip.h {
						draw_text(&rend, it.font, it.size, r.x + 22 * dp, ty, it.text[l.start:l.end], it.color)
					}
					ty += lh
				}
			}
		case .Tool:
			draw_tool(m, &it, r)
		}
	}
}

@(private = "file")
draw_tool :: proc(m: ^Message, it: ^Item, r: Rect) {
	dp := ui.dp
	draw_rrect(&rend, r, 10 * dp, COL_CARD)
	head := Rect{r.x, r.y, r.w, 40 * dp}
	if ui_pressed(head) do draw_rrect(&rend, head, 10 * dp, COL_CARD_HI)
	icon_chevron(r.x + 14 * dp, head.y + head.h / 2, 8 * dp, it.expanded, COL_DIM)
	// status dot
	dot_col := COL_FAINT
	switch it.tool_status {
	case 1: dot_col = COL_WARN
	case 2: dot_col = COL_OK
	case 3: dot_col = COL_ERROR
	}
	ds := 8 * dp
	dx := r.x + r.w - 14 * dp - ds
	if it.tool_status == 1 {
		spinner(dx + ds / 2, head.y + head.h / 2, 14 * dp, COL_WARN)
	} else {
		draw_rrect(&rend, {dx, head.y + (head.h - ds) / 2, ds, ds}, ds / 2, dot_col)
	}
	ns := 14 * dp
	tx := r.x + 28 * dp
	nw := draw_text(&rend, FONT_BOLD, ns, tx, head.y + (head.h - font_line_height(FONT_BOLD, ns)) / 2, fit_text(FONT_BOLD, ns, it.title, r.w * 0.45), COL_TEXT)
	if len(it.subtitle) > 0 {
		sx := tx + nw + 10 * dp
		ss := S_CODE * dp
		avail := dx - 8 * dp - sx
		if avail > 20 * dp {
			draw_text(&rend, FONT_MONO, ss, sx, head.y + (head.h - font_line_height(FONT_MONO, ss)) / 2, fit_text(FONT_MONO, ss, it.subtitle, avail), COL_DIM)
		}
	}
	if ui_tap(head) {
		toggle_expanded(it.key)
		m.dirty = true
	}
	if !it.expanded do return
	pad := 12 * dp
	lh := font_line_height(FONT_MONO, it.size)
	ls := S_SMALL * dp
	label_h := font_line_height(FONT_SANS, ls) + 4 * dp
	y := head.y + head.h
	section :: proc(label: string, text: string, lines: []Line, font: int, size: f32, x, y: ^f32, w, lh, label_h, ls: f32, col: Color) {
		draw_text(&rend, FONT_BOLD, ls, x^, y^, label, COL_FAINT)
		y^ += label_h
		box := Rect{x^ - 6 * ui.dp, y^ - 3 * ui.dp, w + 12 * ui.dp, f32(len(lines)) * lh + 6 * ui.dp}
		draw_rrect(&rend, box, 6 * ui.dp, COL_CODE_BG)
		ty := y^
		for l in lines {
			if ty + lh >= rend.clip.y && ty <= rend.clip.y + rend.clip.h {
				draw_text(&rend, font, size, x^, ty, text[l.start:l.end], col)
			}
			ty += lh
		}
		y^ = ty + 8 * ui.dp
	}
	x := r.x + pad
	if len(it.lines) > 0 {
		section("INPUT", it.text, it.lines[:], FONT_MONO, it.size, &x, &y, r.w - pad * 2, lh, label_h, ls, COL_TEXT)
	}
	if len(it.out_lines) > 0 {
		section(it.tool_status == 3 ? "ERROR" : "OUTPUT", it.out_text, it.out_lines[:], FONT_MONO, it.size, &x, &y, r.w - pad * 2, lh, label_h, ls, it.tool_status == 3 ? COL_ERROR : COL_TEXT)
	}
}

toggle_expanded :: proc(key: string) {
	if k, ok := app.expanded[key]; ok {
		app.expanded[key] = !k
	} else {
		app.expanded[strings.clone(key)] = true
	}
}

_ :: math

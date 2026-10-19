package main

// Screen drawing: connect, sessions, new session, chat, overlays.

import "core:fmt"
import "core:math"
import "core:strings"

HEADER_H :: 56

app_draw :: proc(area: Rect) {
	overlay := app.dialog.active || app.model_picker
	saved_tap, saved_lp := ui.tap, ui.long_press
	if overlay {
		ui.tap = false
		ui.long_press = false
	}

	switch app.screen {
	case .Connect:
		draw_connect(area)
	case .Sessions:
		draw_sessions(area)
	case .New_Session:
		draw_new_session(area)
	case .Chat:
		draw_chat(area)
	}

	if overlay {
		ui.tap, ui.long_press = saved_tap, saved_lp
		if app.model_picker do draw_model_picker(area)
		if app.dialog.active do draw_dialog(area)
	}
	draw_toast(area)

	// tapping empty space dismisses the keyboard
	if ui.tap && ui.focus != nil {
		tf_blur()
		ui.tap = false
	}
}

// --- shared pieces -------------------------------------------------------------------

header :: proc(area: Rect, title: string, subtitle := "", back := false) -> (back_tapped: bool, subtitle_tapped: bool) {
	dp := ui.dp
	bar := Rect{area.x, area.y, area.w, HEADER_H * dp}
	draw_rect(&rend, bar, COL_PANEL)
	draw_rect(&rend, {bar.x, bar.y + bar.h - 1, bar.w, 1}, COL_BORDER)
	x := bar.x + 16 * dp
	if back {
		br := Rect{bar.x + 4 * dp, bar.y + 4 * dp, 48 * dp, 48 * dp}
		if icon_button(br) do back_tapped = true
		icon_chevron_left(br.x + br.w / 2, br.y + br.h / 2, 16 * dp, COL_TEXT)
		x = br.x + br.w + 2 * dp
	}
	ts := 17 * dp
	max_w := bar.x + bar.w - x - 110 * dp
	if len(subtitle) > 0 {
		draw_text(&rend, FONT_BOLD, ts, x, bar.y + 8 * dp, fit_text(FONT_BOLD, ts, title, max_w), COL_TEXT)
		ss := 12.5 * dp
		sr := Rect{x, bar.y + 31 * dp, max_w, 20 * dp}
		draw_text(&rend, FONT_SANS, ss, x, sr.y, fit_text(FONT_SANS, ss, subtitle, max_w), COL_DIM)
		if ui_tap(sr) do subtitle_tapped = true
	} else {
		draw_text(&rend, FONT_BOLD, ts, x, bar.y + (bar.h - font_line_height(FONT_BOLD, ts)) / 2, fit_text(FONT_BOLD, ts, title, max_w), COL_TEXT)
	}
	return
}

// Right-aligned header icon slot i (0 = rightmost).
header_slot :: proc(area: Rect, i: int) -> Rect {
	dp := ui.dp
	return {area.x + area.w - (4 + 48 * f32(i + 1)) * dp, area.y + 4 * dp, 48 * dp, 48 * dp}
}

conn_banner :: proc(area: Rect, y: f32) -> f32 {
	if conn.state == .Open do return 0
	dp := ui.dp
	h := 26 * dp
	r := Rect{area.x, y, area.w, h}
	draw_rect(&rend, r, Color{70, 52, 20, 255})
	msg := "Connecting…"
	if conn.state == .Closed {
		secs := max(0, int((app.reconnect_at - now_ms()) / 1000) + 1)
		msg = app.reconnect_at > 0 ? fmt.tprintf("Disconnected — retrying in %ds (tap to retry)", secs) : "Disconnected (tap to reconnect)"
		if app.reconnect_at > 0 do request_redraw(500)
	}
	ss := 12.5 * dp
	draw_text(&rend, FONT_SANS, ss, r.x + 16 * dp, r.y + (h - font_line_height(FONT_SANS, ss)) / 2, fit_text(FONT_SANS, ss, msg, r.w - 32 * dp), COL_WARN)
	if ui_tap(r) && conn.state == .Closed {
		app.connect_wanted = true
		app_connect()
	}
	return h
}

draw_toast :: proc(area: Rect) {
	if len(app.toast_text) == 0 || now_ms() > app.toast_until do return
	dp := ui.dp
	ss := 14 * dp
	pad := 14 * dp
	max_w := min(area.w - 48 * dp, 520 * dp)
	lines := make([dynamic]Line, 0, 4, context.temp_allocator)
	wrap_text(FONT_SANS, ss, app.toast_text, max_w - pad * 2, &lines)
	if len(lines) > 4 do resize(&lines, 4)
	lh := font_line_height(FONT_SANS, ss)
	widest: f32 = 0
	for l in lines do widest = max(widest, measure_text(FONT_SANS, ss, app.toast_text[l.start:l.end]))
	w := widest + pad * 2
	h := f32(len(lines)) * lh + pad * 1.4
	r := Rect{area.x + (area.w - w) / 2, area.y + area.h - h - 96 * dp, w, h}
	draw_rrect(&rend, r, 12 * dp, Color{50, 56, 72, 245})
	y := r.y + pad * 0.7
	for l in lines {
		draw_text(&rend, FONT_SANS, ss, r.x + pad, y, app.toast_text[l.start:l.end], COL_TEXT)
		y += lh
	}
	if ui_tap(r) do app.toast_until = 0
}

label :: proc(x, y: f32, s: string, col := COL_DIM) -> f32 {
	ss := 13 * ui.dp
	draw_text(&rend, FONT_BOLD, ss, x, y, s, col)
	return font_line_height(FONT_BOLD, ss) + 6 * ui.dp
}

// --- connect ------------------------------------------------------------------------

draw_connect :: proc(area: Rect) {
	dp := ui.dp
	w := min(area.w - 40 * dp, 440 * dp)
	x := area.x + (area.w - w) / 2
	y := area.y + max(40 * dp, area.h * 0.12)
	if ui.focus != nil do y = area.y + 24 * dp

	// logo mark
	draw_rrect(&rend, {x, y, 44 * dp, 44 * dp}, 12 * dp, COL_ACCENT)
	draw_text(&rend, FONT_BOLD, 24 * dp, x + 12 * dp, y + 6 * dp, "π", COL_BG)
	draw_text(&rend, FONT_BOLD, 24 * dp, x + 58 * dp, y + 6 * dp, "Pi Agent", COL_TEXT)
	y += 60 * dp
	y += draw_paragraph(x, y, w, "Native Android client for pi-agent-webui. Written in Odin; draws its own UI with OpenGL ES.", 14 * dp, COL_DIM)
	y += 18 * dp

	y += label(x, y, "SERVER ADDRESS")
	fh := 48 * dp
	submitted := text_field(&app.host_field, {x, y, w, fh}, "192.168.1.20:7860", 16 * dp)
	y += fh + 14 * dp
	y += label(x, y, "TOKEN (OPTIONAL)")
	submitted |= text_field(&app.token_field, {x, y, w, fh}, "PI_WEBUI_TOKEN", 16 * dp)
	y += fh + 20 * dp

	busy := conn.state == .Connecting || conn.state == .Handshake
	if conn.state == .Open {
		if button({x, y, w, 48 * dp}, "Open sessions") {
			tf_blur()
			app.screen = .Sessions
		}
		y += 56 * dp
		if button({x, y, w, 44 * dp}, "Disconnect", COL_CARD, COL_TEXT) do app_disconnect()
		y += 52 * dp
	} else {
		if button({x, y, w, 48 * dp}, busy ? "Connecting…" : "Connect", enabled = !busy) || (submitted && !busy) {
			tf_blur()
			app.ever_connected = false
			app_connect()
		}
		y += 60 * dp
		if busy {
			spinner(x + w / 2, y + 10 * dp, 20 * dp, COL_ACCENT)
			y += 30 * dp
		}
	}
	if conn.state == .Closed && len(conn.error) > 0 {
		y += draw_paragraph(x, y, w, conn.error, 14 * dp, COL_ERROR) + 10 * dp
	}
	y += 10 * dp
	draw_paragraph(x, y, w, "Tip: on the emulator the host machine is 10.0.2.2. To reach the server from a phone, start it with PI_WEBUI_HOST=0.0.0.0 and use your computer's LAN or Tailscale IP.", 12.5 * dp, COL_FAINT)
}

draw_paragraph :: proc(x, y, w: f32, text: string, size: f32, col: Color) -> f32 {
	lines := make([dynamic]Line, 0, 8, context.temp_allocator)
	wrap_text(FONT_SANS, size, text, w, &lines)
	lh := font_line_height(FONT_SANS, size)
	yy := y
	for l in lines {
		draw_text(&rend, FONT_SANS, size, x, yy, text[l.start:l.end], col)
		yy += lh
	}
	return yy - y
}

// --- sessions ---------------------------------------------------------------------------

draw_sessions :: proc(area: Rect) {
	dp := ui.dp
	header(area, "Sessions")
	// right icons: new, refresh, server
	r0 := header_slot(area, 0)
	if icon_button(r0) do app.screen = .New_Session
	icon_plus(r0.x + r0.w / 2, r0.y + r0.h / 2, 18 * dp, COL_TEXT)
	r1 := header_slot(area, 1)
	if icon_button(r1) && conn.state == .Open {
		app.sessions_loading = true
		rpc_call("sessions.list", "", .Sessions_List)
	}
	if app.sessions_loading do spinner(r1.x + r1.w / 2, r1.y + r1.h / 2, 18 * dp, COL_TEXT)
	else do icon_refresh(r1.x + r1.w / 2, r1.y + r1.h / 2, 16 * dp, COL_TEXT)
	r2 := header_slot(area, 2)
	if icon_button(r2) do app.screen = .Connect
	dc := conn.state == .Open ? COL_OK : (conn.state == .Closed ? COL_ERROR : COL_WARN)
	draw_rrect(&rend, {r2.x + r2.w / 2 - 5 * dp, r2.y + r2.h / 2 - 5 * dp, 10 * dp, 10 * dp}, 5 * dp, dc)

	top := area.y + HEADER_H * dp
	top += conn_banner(area, top)
	view := Rect{area.x, top, area.w, area.y + area.h - top}

	if !app.sessions_loaded {
		if conn.state == .Open do spinner(view.x + view.w / 2, view.y + 80 * dp, 26 * dp, COL_ACCENT)
		return
	}
	if len(app.sessions) == 0 {
		draw_paragraph(view.x + 24 * dp, view.y + 40 * dp, view.w - 48 * dp, "No sessions yet. Tap + to start one.", 15 * dp, COL_DIM)
		return
	}

	s := &app.sessions_scroll
	scroll_begin(s, view)
	pad := 12 * dp
	item_h := 70 * dp
	y := view.y + pad - s.offset
	x := view.x + pad
	w := view.w - pad * 2
	for &it in app.sessions {
		r := Rect{x, y, w, item_h}
		if r.y + r.h >= view.y && r.y <= view.y + view.h {
			draw_rrect(&rend, r, 12 * dp, ui_pressed(r) ? COL_CARD_HI : COL_CARD)
			title := len(it.name) > 0 ? it.name : it.first
			title = strings.trim_space(title)
			if i := strings.index_byte(title, '\n'); i >= 0 do title = title[:i]
			if len(title) == 0 do title = "(empty session)"
			ts := 15.5 * dp
			running := app.running_ids[it.id]
			tw := w - 28 * dp - (running ? 24 * dp : 0)
			draw_text(&rend, FONT_BOLD, ts, r.x + 14 * dp, r.y + 12 * dp, fit_text(FONT_BOLD, ts, title, tw), COL_TEXT)
			ss := 12.5 * dp
			sub := fmt.tprintf("%s  ·  %s  ·  %d msgs", path_base(it.cwd), relative_time(it.mod_time), it.count)
			draw_text(&rend, FONT_SANS, ss, r.x + 14 * dp, r.y + 40 * dp, fit_text(FONT_SANS, ss, sub, w - 28 * dp), COL_DIM)
			if running do spinner(r.x + r.w - 22 * dp, r.y + 22 * dp, 14 * dp, COL_OK)
			if ui_tap(r) do open_session(it)
			if ui_long_press(r) {
				plat_clipboard_set(it.cwd)
				toast(fmt.tprintf("Copied path: %s", it.cwd))
			}
		}
		y += item_h + 8 * dp
	}
	scroll_end(s, y + s.offset - view.y + pad)
}

// --- new session -----------------------------------------------------------------------

draw_new_session :: proc(area: Rect) {
	dp := ui.dp
	back, _ := header(area, "New session", "", true)
	if back {
		app_back()
		return
	}
	top := area.y + HEADER_H * dp
	top += conn_banner(area, top)
	pad := 16 * dp
	x := area.x + pad
	w := area.w - pad * 2
	y := top + pad
	y += label(x, y, "WORKING DIRECTORY (ON THE SERVER)")
	fh := 48 * dp
	submitted := text_field(&app.cwd_field, {x, y, w, fh}, "/home/me/project", 15 * dp)
	y += fh + 12 * dp
	cwd := strings.trim_space(tf_text(&app.cwd_field))
	if button({x, y, w, 46 * dp}, "Start session", enabled = len(cwd) > 0) || (submitted && len(cwd) > 0) {
		start_new_session(cwd)
		return
	}
	y += 62 * dp
	if len(app.recent_cwds) == 0 do return
	y += label(x, y, "RECENT DIRECTORIES")
	view := Rect{area.x, y, area.w, area.y + area.h - y}
	s := &app.new_scroll
	scroll_begin(s, view)
	yy := view.y - s.offset
	row_h := 52 * dp
	for d in app.recent_cwds {
		r := Rect{x, yy, w, row_h}
		if r.y + r.h >= view.y && r.y <= view.y + view.h {
			draw_rrect(&rend, r, 10 * dp, ui_pressed(r) ? COL_CARD_HI : COL_CARD)
			draw_text(&rend, FONT_BOLD, 14.5 * dp, r.x + 14 * dp, r.y + 7 * dp, fit_text(FONT_BOLD, 14.5 * dp, path_base(d), w - 28 * dp), COL_TEXT)
			draw_text(&rend, FONT_MONO, 12 * dp, r.x + 14 * dp, r.y + 29 * dp, fit_text(FONT_MONO, 12 * dp, d, w - 28 * dp), COL_DIM)
			if ui_tap(r) {
				tf_set(&app.cwd_field, d)
				start_new_session(d)
				scroll_end(s, 0)
				return
			}
		}
		yy += row_h + 6 * dp
	}
	scroll_end(s, yy + s.offset - view.y + 16 * dp)
}

// --- chat -----------------------------------------------------------------------------

draw_chat :: proc(area: Rect) {
	dp := ui.dp
	c := &app.chat
	subtitle := fmt.tprintf("%s  ·  %s", model_label(), path_base(c.cwd))
	back, sub_tapped := header(area, len(c.title) > 0 ? c.title : "Session", subtitle, true)
	if back {
		app_back()
		return
	}
	if sub_tapped {
		app.model_picker = true
		tf_set(&app.model_filter, "")
		app.model_scroll = {}
		if len(app.models) == 0 do rpc_call("models.list", "", .Models_List)
	}
	if len(c.sid) > 0 {
		r0 := header_slot(area, 0)
		if icon_button(r0) do chat_reload()
		if c.loading do spinner(r0.x + r0.w / 2, r0.y + r0.h / 2, 18 * dp, COL_TEXT)
		else do icon_refresh(r0.x + r0.w / 2, r0.y + r0.h / 2, 16 * dp, COL_TEXT)
	}

	top := area.y + HEADER_H * dp
	top += conn_banner(area, top)

	// composer
	cs := 15.5 * dp
	btn := 46 * dp
	pad := 10 * dp
	comp_w := area.w - pad * 3 - btn
	comp_h := max(btn, text_field_height(&c.composer, comp_w, cs, 6))
	bottom_h := comp_h + pad * 2
	bottom := Rect{area.x, area.y + area.h - bottom_h, area.w, bottom_h}
	view := Rect{area.x, top, area.w, bottom.y - top}

	// transcript
	content_pad := 14 * dp
	cw := view.w - content_pad * 2
	total: f32 = content_pad
	for m, i in c.messages {
		if m.dirty || m.layout_w != cw do layout_message(m, i, cw)
		if m.height > 0 do total += m.height + 14 * dp
	}
	status_h: f32 = 0
	if c.running || c.loading do status_h = 36 * dp
	total += status_h + content_pad

	s := &c.scroll
	if c.stick_bottom do s.offset = max(0, total - view.h)
	scroll_begin(s, view)
	y := view.y + content_pad - s.offset
	for m in c.messages {
		if m.height <= 0 do continue
		if y + m.height >= view.y && y <= view.y + view.h {
			draw_message(m, view.x + content_pad, y)
			r := Rect{view.x, y, view.w, m.height}
			if ui_long_press(r) {
				plat_clipboard_set(message_plain_text(m))
				toast("Copied message")
			}
		}
		y += m.height + 14 * dp
	}
	if status_h > 0 {
		spinner(view.x + content_pad + 9 * dp, y + 14 * dp, 16 * dp, COL_ACCENT)
		phase := c.loading ? "Loading…" : (len(c.phase) > 0 ? c.phase : "Streaming…")
		draw_text(&rend, FONT_SANS, 13.5 * dp, view.x + content_pad + 26 * dp, y + 14 * dp - font_line_height(FONT_SANS, 13.5 * dp) / 2, phase, COL_DIM)
	}
	if len(c.messages) == 0 && !c.loading {
		msg := c.is_new ? fmt.tprintf("New session in %s\n\nAsk Pi to do something.", c.cwd) : "No messages yet."
		draw_paragraph(view.x + 28 * dp, view.y + 60 * dp, view.w - 56 * dp, msg, 15 * dp, COL_DIM)
	}
	scroll_end(s, total)
	if s.dragged || s.velocity != 0 {
		c.stick_bottom = scroll_at_bottom(s)
		s.dragged = false
	}

	// jump-to-bottom button
	if !c.stick_bottom && total > view.h {
		jr := Rect{view.x + view.w - 58 * dp, view.y + view.h - 58 * dp, 44 * dp, 44 * dp}
		draw_rrect(&rend, jr, 22 * dp, COL_CARD_HI)
		icon_chevron(jr.x + jr.w / 2, jr.y + jr.h / 2, 14 * dp, true, COL_TEXT)
		if ui_tap(jr) {
			c.stick_bottom = true
			s.velocity = 0
		}
	}

	// bottom bar
	draw_rect(&rend, bottom, COL_PANEL)
	draw_rect(&rend, {bottom.x, bottom.y, bottom.w, 1}, COL_BORDER)
	fr := Rect{bottom.x + pad, bottom.y + pad, comp_w, comp_h}
	text_field(&c.composer, fr, c.running ? "Queue a follow-up…" : "Message Pi…", cs, 6)
	br := Rect{fr.x + fr.w + pad, bottom.y + bottom_h - pad - btn, btn, btn}
	has_text := len(strings.trim_space(tf_text(&c.composer))) > 0
	if c.running && !has_text {
		draw_rrect(&rend, br, btn / 2, ui_pressed(br) ? COL_ERROR : Color{200, 80, 80, 255})
		icon_stop(br.x + br.w / 2, br.y + br.h / 2, 14 * dp, COL_TEXT)
		if ui_tap(br) do chat_abort()
	} else {
		col := has_text ? COL_ACCENT : COL_CARD
		if ui_pressed(br) && has_text do col = COL_ACCENT_D
		draw_rrect(&rend, br, btn / 2, col)
		icon_send(br.x + br.w / 2 + 1 * dp, br.y + br.h / 2, 16 * dp, has_text ? COL_BG : COL_FAINT)
		if ui_tap(br) && has_text do chat_send()
	}
}

// --- overlays ---------------------------------------------------------------------------

draw_model_picker :: proc(area: Rect) {
	dp := ui.dp
	draw_rect(&rend, area, COL_BG)
	back, _ := header(area, "Choose model", "", true)
	if back {
		app.model_picker = false
		tf_blur()
		return
	}
	top := area.y + HEADER_H * dp
	pad := 12 * dp
	fh := 46 * dp
	text_field(&app.model_filter, {area.x + pad, top + pad, area.w - pad * 2, fh}, "Filter models", 15 * dp)
	top += fh + pad * 2
	view := Rect{area.x, top, area.w, area.y + area.h - top}
	filter := strings.to_lower(strings.trim_space(tf_text(&app.model_filter)), context.temp_allocator)
	s := &app.model_scroll
	scroll_begin(s, view)
	y := view.y - s.offset
	row_h := 56 * dp
	x := area.x + pad
	w := area.w - pad * 2
	if len(app.models) == 0 {
		draw_paragraph(x + 8 * dp, y + 20 * dp, w, "No models available (configure providers in the web UI).", 14 * dp, COL_DIM)
	}
	for m in app.models {
		if len(filter) > 0 {
			hay := strings.to_lower(fmt.tprintf("%s %s %s", m.name, m.id, m.provider), context.temp_allocator)
			if !strings.contains(hay, filter) do continue
		}
		r := Rect{x, y, w, row_h}
		if r.y + r.h >= view.y && r.y <= view.y + view.h {
			sel := m.id == app.chat.model_id && m.provider == app.chat.provider
			draw_rrect(&rend, r, 10 * dp, sel ? COL_USER : (ui_pressed(r) ? COL_CARD_HI : COL_CARD))
			name := len(m.name) > 0 ? m.name : m.id
			draw_text(&rend, FONT_BOLD, 14.5 * dp, r.x + 14 * dp, r.y + 8 * dp, fit_text(FONT_BOLD, 14.5 * dp, name, w - 28 * dp), COL_TEXT)
			draw_text(&rend, FONT_SANS, 12 * dp, r.x + 14 * dp, r.y + 31 * dp, fit_text(FONT_SANS, 12 * dp, fmt.tprintf("%s / %s", m.provider, m.id), w - 28 * dp), COL_DIM)
			if ui_tap(r) {
				chat_set_model_remote(m)
				app.model_picker = false
				tf_blur()
			}
		}
		y += row_h + 6 * dp
	}
	scroll_end(s, y + s.offset - view.y + pad)
	ui.tap = false // modal
}

dialog_scroll: Scroll

draw_dialog :: proc(area: Rect) {
	dp := ui.dp
	d := &app.dialog
	draw_rect(&rend, area, Color{0, 0, 0, 170})
	w := min(area.w - 32 * dp, 460 * dp)
	pad := 18 * dp
	inner := w - pad * 2
	// measure
	ts := 16.5 * dp
	ms := 14 * dp
	tl := make([dynamic]Line, 0, 4, context.temp_allocator)
	wrap_text(FONT_BOLD, ts, d.title, inner, &tl)
	ml := make([dynamic]Line, 0, 8, context.temp_allocator)
	if len(d.message) > 0 do wrap_text(FONT_SANS, ms, d.message, inner, &ml)
	h := pad * 2 + f32(len(tl)) * font_line_height(FONT_BOLD, ts) + 10 * dp
	if len(ml) > 0 do h += f32(min(len(ml), 12)) * font_line_height(FONT_SANS, ms) + 12 * dp
	opt_h := 48 * dp
	switch d.method {
	case "select":
		h += min(f32(len(d.options)) * (opt_h + 6 * dp), area.h * 0.5) + 50 * dp
	case "confirm":
		h += 52 * dp
	case "input":
		h += 48 * dp + 64 * dp
	case "editor":
		h += 140 * dp + 64 * dp
	}
	h = min(h, area.h - 32 * dp)
	r := Rect{area.x + (area.w - w) / 2, area.y + max(16 * dp, (area.h - h) / 2), w, h}
	draw_rrect(&rend, r, 16 * dp, COL_PANEL)
	x := r.x + pad
	y := r.y + pad
	for l in tl {
		draw_text(&rend, FONT_BOLD, ts, x, y, d.title[l.start:l.end], COL_TEXT)
		y += font_line_height(FONT_BOLD, ts)
	}
	y += 10 * dp
	for l, i in ml {
		if i >= 12 do break
		draw_text(&rend, FONT_SANS, ms, x, y, d.message[l.start:l.end], COL_DIM)
		y += font_line_height(FONT_SANS, ms)
	}
	if len(ml) > 0 do y += 12 * dp
	half := (inner - 10 * dp) / 2
	switch d.method {
	case "select":
		list_h := r.y + r.h - pad - 50 * dp - y
		view := Rect{x, y, inner, list_h}
		scroll_begin(&dialog_scroll, view)
		yy := y - dialog_scroll.offset
		for o in d.options {
			orr := Rect{x, yy, inner, opt_h}
			draw_rrect(&rend, orr, 10 * dp, ui_pressed(orr) ? COL_CARD_HI : COL_CARD)
			draw_text(&rend, FONT_SANS, 14.5 * dp, orr.x + 14 * dp, orr.y + (opt_h - font_line_height(FONT_SANS, 14.5 * dp)) / 2, fit_text(FONT_SANS, 14.5 * dp, o, inner - 28 * dp), COL_TEXT)
			if ui_tap(orr) {
				scroll_end(&dialog_scroll, 0)
				dialog_respond(o, false, false)
				return
			}
			yy += opt_h + 6 * dp
		}
		scroll_end(&dialog_scroll, yy + dialog_scroll.offset - y)
		if button({x, r.y + r.h - pad - 42 * dp, inner, 42 * dp}, "Cancel", COL_CARD, COL_TEXT) do dialog_respond("", false, true)
	case "confirm":
		by := r.y + r.h - pad - 44 * dp
		if button({x, by, half, 44 * dp}, "Cancel", COL_CARD, COL_TEXT) do dialog_respond("", false, false)
		else if button({x + half + 10 * dp, by, half, 44 * dp}, "Confirm") do dialog_respond("", true, false)
	case "input", "editor":
		fh := d.method == "editor" ? 140 * dp : 48 * dp
		d.field.multiline = d.method == "editor"
		submitted := text_field(&d.field, {x, y, inner, fh}, "", 15 * dp, 6)
		by := r.y + r.h - pad - 44 * dp
		if button({x, by, half, 44 * dp}, "Cancel", COL_CARD, COL_TEXT) do dialog_respond("", false, true)
		else if button({x + half + 10 * dp, by, half, 44 * dp}, "OK") || submitted do dialog_respond(tf_text(&d.field), false, false)
	}
	ui.tap = false // modal: swallow taps outside
}

_ :: math

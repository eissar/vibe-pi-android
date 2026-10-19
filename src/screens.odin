package main

// All screens, declared with Clay every frame.

import "core:fmt"
import "core:strings"
import clay "clay"
import sdl "vendor:sdl3"

CHAT_SCROLL :: "chat-scroll"
safe_top: u16
MAX_TOOL_CHARS :: 12000

app_layout :: proc(safe: sdl.Rect) {
	ui.modal = app.dialog.active || app.model_picker
	top := f32(safe.y)
	safe_top = u16(max(top, 0))
	bottom := plat.h - f32(safe.y + safe.h)
	if clay.UI(clay.ID("root"))({
		layout = {sizing = {grow(), grow()}, layoutDirection = .TopToBottom, padding = {0, 0, u16(max(top, 0)), u16(max(bottom, 0))}},
		backgroundColor = COL_BG,
	}) {
		switch app.screen {
		case .Connect:
			connect_screen()
		case .Sessions:
			sessions_screen()
		case .New_Session:
			new_session_screen()
		case .Chat:
			chat_screen()
		}
		ui.modal = false
		if app.model_picker do model_picker()
		if app.dialog.active do dialog()
		toast_view()
	}
	if ui.tap && ui.focus != nil do tf_blur() // tap outside any field dismisses the keyboard
}

// Stick the chat to the bottom while new output streams in.
app_after_layout :: proc() {
	if app.screen != .Chat do return
	d := clay.GetScrollContainerData(clay.ID(CHAT_SCROLL))
	if !d.found do return
	max_scroll := max(0, d.contentDimensions.height - d.scrollContainerDimensions.height)
	if ui.down && ui.dragging {
		app.chat.stick_bottom = -d.scrollPosition.y >= max_scroll - dpx(24)
	} else if app.chat.stick_bottom {
		d.scrollPosition.y = -max_scroll
	} else if -d.scrollPosition.y >= max_scroll - 2 {
		app.chat.stick_bottom = true
	}
}

// --- shared --------------------------------------------------------------------------

header :: proc(title: string, subtitle := "", back := false) -> (back_tapped, subtitle_tapped: bool) {
	if clay.UI(clay.ID("header"))({
		layout = {sizing = {grow(), fixed(56)}, childAlignment = {y = .Center}, padding = {dpu(back ? 4 : 16), dpu(4), 0, 0}, childGap = dpu(4)},
		backgroundColor = COL_PANEL,
		border = {color = COL_BORDER, width = {bottom = 1}},
	}) {
		if back do back_tapped = icon_button("hdr-back", .Back)
		sid := clay.ID("hdr-title")
		if clay.UI(sid)({layout = {sizing = {grow(), fit()}, layoutDirection = .TopToBottom, childGap = dpu(2)}}) {
			text_line(title, 17, COL_TEXT, FONT_BOLD)
			if len(subtitle) > 0 do text_line(subtitle, 12.5, COL_DIM)
		}
		subtitle_tapped = len(subtitle) > 0 && clicked(sid)
		header_actions()
	}
	return
}

// Filled in by each screen right before calling header().
header_actions_proc: proc()
header_actions :: proc() {
	if header_actions_proc != nil do header_actions_proc()
	header_actions_proc = nil
}

conn_banner :: proc() {
	if conn.state == .Open do return
	msg := "Connecting…"
	if conn.state == .Closed {
		secs := max(0, int((app.reconnect_at - now_ms()) / 1000) + 1)
		msg = app.reconnect_at > 0 ? fmt.tprintf("Disconnected — retrying in %ds (tap to retry)", secs) : "Disconnected (tap to reconnect)"
		ui.animating = app.reconnect_at > 0
	}
	id := clay.ID("banner")
	if clay.UI(id)({layout = {sizing = {grow(), fit()}, padding = pad(16, 6)}, backgroundColor = {70, 52, 20, 255}}) {
		text(msg, 12.5, COL_WARN)
	}
	if clicked(id) && conn.state == .Closed {
		app.connect_wanted = true
		app_connect()
	}
}

section_label :: proc(s: string) {
	text(s, 12.5, COL_DIM, FONT_BOLD)
}

toast_view :: proc() {
	if len(app.toast_text) == 0 || now_ms() > app.toast_until do return
	ui.animating = true
	id := clay.ID("toast")
	if clay.UI(id)({
		floating = {attachTo = .Root, attachment = {element = .CenterBottom, parent = .CenterBottom}, offset = {0, -dpx(96)}, zIndex = 100},
		layout = {sizing = {fit({max = min(plat.w - dpx(48), dpx(520))}), fit()}, padding = pad(14, 10)},
		backgroundColor = {50, 56, 72, 245},
		cornerRadius = radius(12),
	}) {
		text(app.toast_text, 14)
	}
	if ui.tap && clay.PointerOver(id) do app.toast_until = 0
}

// --- connect --------------------------------------------------------------------------

connect_screen :: proc() {
	if clay.UI()({layout = {sizing = {grow(), grow()}, childAlignment = {x = .Center}, padding = pad(20, 32)}, clip = {vertical = true, childOffset = clay.GetScrollOffset()}}) {
		if clay.UI()({layout = {sizing = {grow({max = dpx(440)}), fit()}, layoutDirection = .TopToBottom, childGap = dpu(10)}}) {
			if clay.UI()({layout = {childGap = dpu(14), childAlignment = {y = .Center}}}) {
				if clay.UI()({layout = {sizing = {fixed(44), fixed(44)}, childAlignment = {.Center, .Center}}, backgroundColor = COL_ACCENT, cornerRadius = radius(12)}) {
					text("π", 24, COL_BG, FONT_BOLD)
				}
				text("Pi Agent", 24, COL_TEXT, FONT_BOLD)
			}
			text("Native Android client for pi-agent-webui. Odin + SDL3 + Clay.", 14, COL_DIM)
			spacer(10)
			section_label("SERVER ADDRESS")
			submitted := text_field("host", &app.host_field, "192.168.1.20:7860")
			spacer(4)
			section_label("TOKEN (OPTIONAL)")
			submitted |= text_field("token", &app.token_field, "PI_WEBUI_TOKEN")
			spacer(8)
			busy := conn.state == .Connecting || conn.state == .Handshake
			if conn.state == .Open {
				if button("open", "Open sessions") {
					tf_blur()
					app.screen = .Sessions
				}
				if button("disc", "Disconnect", COL_CARD, COL_TEXT) do app_disconnect()
			} else if button("connect", busy ? "Connecting…" : "Connect", enabled = !busy) || (submitted && !busy) {
				tf_blur()
				app.ever_connected = false
				app_connect()
			}
			if busy do icon(.Spinner, 22, COL_ACCENT)
			if conn.state == .Closed && len(conn.error) > 0 do text(conn.error, 14, COL_ERROR)
			spacer(8)
			text("Tip: the emulator reaches the host at 10.0.2.2. For a phone, run the server with PI_WEBUI_HOST=0.0.0.0 and use your computer's LAN or Tailscale IP.", 12.5, COL_FAINT)
		}
	}
}

spacer :: proc(h: f32) {
	if clay.UI()({layout = {sizing = {grow(), fixed(h)}}}) {}
}

// --- sessions ------------------------------------------------------------------------------

sessions_screen :: proc() {
	header_actions_proc = proc() {
		dot := conn.state == .Open ? COL_OK : (conn.state == .Closed ? COL_ERROR : COL_WARN)
		if icon_button("srv", .Dot, dot) do app.screen = .Connect
		if app.sessions_loading {
			if clay.UI()({layout = {sizing = {fixed(48), fixed(48)}, childAlignment = {.Center, .Center}}}) do icon(.Spinner, 18, COL_TEXT)
		} else if icon_button("refresh", .Refresh) && conn.state == .Open {
			app.sessions_loading = true
			rpc_call("sessions.list", "", .Sessions_List)
		}
		if icon_button("new", .Plus) do app.screen = .New_Session
	}
	header("Sessions")
	conn_banner()
	if !app.sessions_loaded {
		if conn.state == .Open do centered_spinner()
		return
	}
	if len(app.sessions) == 0 {
		if clay.UI()({layout = {padding = pad(24, 40)}}) do text("No sessions yet. Tap + to start one.", 15, COL_DIM)
		return
	}
	if clay.UI(clay.ID("sess-scroll"))({
		layout = {sizing = {grow(), grow()}, layoutDirection = .TopToBottom, padding = pad(12, 12), childGap = dpu(8)},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	}) {
		for &it, i in app.sessions {
			id := clay.ID("sess", u32(i))
			if clay.UI(id)({
				layout = {sizing = {grow(), fit()}, layoutDirection = .TopToBottom, padding = pad(14, 12), childGap = dpu(6)},
				backgroundColor = hover_col(id, COL_CARD, COL_CARD_HI),
				cornerRadius = radius(12),
			}) {
				title := strings.trim_space(len(it.name) > 0 ? it.name : it.first)
				if len(title) == 0 do title = "(empty session)"
				if clay.UI()({layout = {sizing = {grow(), fit()}, childGap = dpu(8), childAlignment = {y = .Center}}}) {
					text_line(title, 15.5, COL_TEXT, FONT_BOLD)
					if app.running_ids[it.id] do icon(.Spinner, 14, COL_OK)
				}
				text_line(fmt.tprintf("%s  ·  %s  ·  %d msgs", path_base(it.cwd), relative_time(it.mod_time), it.count), 12.5, COL_DIM)
			}
			if clicked(id) do open_session(it)
			if long_pressed(id) {
				plat_clipboard_set(it.cwd)
				toast(fmt.tprintf("Copied path: %s", it.cwd))
			}
		}
	}
}

centered_spinner :: proc() {
	if clay.UI()({layout = {sizing = {grow(), fixed(160)}, childAlignment = {.Center, .Center}}}) do icon(.Spinner, 28, COL_ACCENT)
}

// --- new session ---------------------------------------------------------------------------

new_session_screen :: proc() {
	back, _ := header("New session", "", true)
	if back {
		app_back()
		return
	}
	conn_banner()
	if clay.UI(clay.ID("new-scroll"))({
		layout = {sizing = {grow(), grow()}, layoutDirection = .TopToBottom, padding = pad(16, 16), childGap = dpu(10)},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	}) {
		section_label("WORKING DIRECTORY (ON THE SERVER)")
		submitted := text_field("cwd", &app.cwd_field, "/home/me/project", 15)
		cwd := strings.trim_space(tf_text(&app.cwd_field))
		if button("start", "Start session", enabled = len(cwd) > 0) || (submitted && len(cwd) > 0) {
			start_new_session(cwd)
			return
		}
		if len(app.recent_cwds) > 0 {
			spacer(10)
			section_label("RECENT DIRECTORIES")
		}
		for d, i in app.recent_cwds {
			id := clay.ID("cwd", u32(i))
			if clay.UI(id)({
				layout = {sizing = {grow(), fit()}, layoutDirection = .TopToBottom, padding = pad(14, 9), childGap = dpu(4)},
				backgroundColor = hover_col(id, COL_CARD, COL_CARD_HI),
				cornerRadius = radius(10),
			}) {
				text_line(path_base(d), 14.5, COL_TEXT, FONT_BOLD)
				text_line(d, 12, COL_DIM, FONT_MONO)
			}
			if clicked(id) {
				tf_set(&app.cwd_field, d)
				start_new_session(d)
			}
		}
	}
}

// --- chat ----------------------------------------------------------------------------------

chat_screen :: proc() {
	c := &app.chat
	header_actions_proc = proc() {
		if len(app.chat.sid) == 0 do return
		if app.chat.loading {
			if clay.UI()({layout = {sizing = {fixed(48), fixed(48)}, childAlignment = {.Center, .Center}}}) do icon(.Spinner, 18, COL_TEXT)
		} else if icon_button("reload", .Refresh) {
			chat_reload()
		}
	}
	back, sub := header(len(c.title) > 0 ? c.title : "Session", fmt.tprintf("%s  ·  %s", model_label(), path_base(c.cwd)), true)
	if back {
		app_back()
		return
	}
	if sub {
		app.model_picker = true
		tf_set(&app.model_filter, "")
		if len(app.models) == 0 do rpc_call("models.list", "", .Models_List)
	}
	conn_banner()

	if clay.UI(clay.ID(CHAT_SCROLL))({
		layout = {sizing = {grow(), grow()}, layoutDirection = .TopToBottom, padding = pad(14, 14), childGap = dpu(14)},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	}) {
		if len(c.messages) == 0 && !c.loading {
			text(c.is_new ? fmt.tprintf("New session in %s\n\nAsk Pi to do something.", c.cwd) : "No messages yet.", 15, COL_DIM)
		}
		for m in c.messages do message_view(m)
		if c.running || c.loading {
			if clay.UI()({layout = {childGap = dpu(10), childAlignment = {y = .Center}}}) {
				icon(.Spinner, 16, COL_ACCENT)
				text(c.loading ? "Loading…" : (len(c.phase) > 0 ? c.phase : "Streaming…"), 13.5, COL_DIM)
			}
		}
	}

	// jump to bottom
	if !c.stick_bottom {
		id := clay.ID("jump")
		if clay.UI(id)({
			floating = {attachTo = .ElementWithId, parentId = clay.ID(CHAT_SCROLL).id, attachment = {element = .RightBottom, parent = .RightBottom}, offset = {-dpx(14), -dpx(14)}, zIndex = 5},
			layout = {sizing = {fixed(44), fixed(44)}, childAlignment = {.Center, .Center}},
			backgroundColor = COL_CARD_HI,
			cornerRadius = radius(22),
		}) {
			icon(.Chevron_Down, 16, COL_TEXT)
		}
		if clicked(id) do c.stick_bottom = true
	}

	// composer
	if clay.UI()({
		layout = {sizing = {grow(), fit()}, padding = pad(10, 10), childGap = dpu(10), childAlignment = {y = .Bottom}},
		backgroundColor = COL_PANEL,
		border = {color = COL_BORDER, width = {top = 1}},
	}) {
		text_field("composer", &c.composer, c.running ? "Queue a follow-up…" : "Message Pi…", 15.5, 160)
		has_text := len(strings.trim_space(tf_text(&c.composer))) > 0
		id := clay.ID("send")
		stop := c.running && !has_text
		bg := stop ? Color{200, 80, 80, 255} : (has_text ? COL_ACCENT : COL_CARD)
		if clay.UI(id)({layout = {sizing = {fixed(46), fixed(46)}, childAlignment = {.Center, .Center}}, backgroundColor = hover_col(id, bg, lighten(bg)), cornerRadius = radius(23)}) {
			icon(stop ? .Stop : .Send, 16, stop ? COL_TEXT : (has_text ? COL_BG : COL_FAINT))
		}
		if clicked(id) {
			if stop do chat_abort()
			else if has_text do chat_send()
		}
	}
}

// Splits text blocks into paragraphs / fenced code / headings once per message.
parse_parts :: proc(m: ^Message) {
	m.parsed = true
	for blk, bi in m.blocks {
		if blk.kind != .Text do continue
		s := blk.text
		para_start := -1
		code_start := -1
		i := 0
		flush :: proc(m: ^Message, s: string, a, b, bi: int) {
			t := strings.trim(s[a:b], "\n ")
			if len(t) > 0 do append(&m.parts, Part{.Para, t, bi})
		}
		for i < len(s) {
			e := strings.index_byte(s[i:], '\n')
			end := e < 0 ? len(s) : i + e
			line := s[i:end]
			tl := strings.trim_left_space(line)
			switch {
			case strings.has_prefix(tl, "```"):
				if code_start < 0 {
					if para_start >= 0 do flush(m, s, para_start, i, bi)
					para_start = -1
					code_start = min(end + 1, len(s))
				} else {
					append(&m.parts, Part{.Code, strings.trim_right(s[code_start:i], "\n"), bi})
					code_start = -1
				}
			case code_start >= 0:
			case strings.has_prefix(tl, "#"):
				lvl := 0
				for lvl < len(tl) && tl[lvl] == '#' do lvl += 1
				if lvl < len(tl) && tl[lvl] == ' ' {
					if para_start >= 0 do flush(m, s, para_start, i, bi)
					para_start = -1
					append(&m.parts, Part{.Heading, tl[lvl + 1:], bi})
				} else if para_start < 0 {
					para_start = i
				}
			case:
				if para_start < 0 do para_start = i
			}
			i = end + 1
		}
		if code_start >= 0 do append(&m.parts, Part{.Code, strings.trim_right(s[code_start:], "\n"), bi})
		else if para_start >= 0 do flush(m, s, para_start, len(s), bi)
	}
}

message_view :: proc(m: ^Message) {
	if m.role == .Tool_Result && app.chat.calls[m.tool_call_id] != nil do return // shown inside its call
	if !m.parsed do parse_parts(m)
	id := clay.ID("msg", u32(m.uid))
	if m.role == .User {
		if clay.UI(id)({layout = {sizing = {grow(), fit()}, childAlignment = {x = .Right}}}) {
			if clay.UI()({layout = {sizing = {fit({max = plat.w * 0.8}), fit()}, padding = pad(12, 9)}, backgroundColor = COL_USER, cornerRadius = radius(14)}) {
				text(strings.trim_space(message_plain_text(m)), 15)
			}
		}
	} else {
		if clay.UI(id)({layout = {sizing = {grow(), fit()}, layoutDirection = .TopToBottom, childGap = dpu(6)}}) {
			if m.role != .Assistant && len(m.label) > 0 do text(m.label, 12.5, COL_FAINT)
			pi := 0
			for blk, bi in m.blocks {
				switch blk.kind {
				case .Text:
					for pi < len(m.parts) && m.parts[pi].block == bi {
						p := m.parts[pi]
						pi += 1
						switch p.kind {
						case .Para:
							text(p.text, 15)
						case .Heading:
							text(p.text, 17, COL_TEXT, FONT_BOLD)
						case .Code:
							code_box(p.text, COL_TEXT)
						}
					}
				case .Thinking:
					thinking_view(m, bi, blk)
				case .Tool_Call:
					tool_view(blk.name, blk.summary, blk.call_id, blk.text, nil)
				case .Image:
					text("[image]", 12.5, COL_DIM)
				case .Error:
					if clay.UI()({layout = {sizing = {grow(), fit()}, padding = pad(10, 8)}, backgroundColor = COL_ERR_BG, cornerRadius = radius(8)}) {
						text(blk.text, 13, COL_ERROR)
					}
				}
			}
			if m.role == .Tool_Result do tool_view(len(m.tool_name) > 0 ? m.tool_name : "tool result", "", m.tool_call_id, "", m)
		}
	}
	if long_pressed(id) {
		plat_clipboard_set(message_plain_text(m))
		toast("Copied message")
	}
}

code_box :: proc(s: string, col: Color) {
	body := s
	more := 0
	if len(body) > MAX_TOOL_CHARS {
		cut := MAX_TOOL_CHARS
		for cut > 0 && (body[cut] & 0xC0) == 0x80 do cut -= 1
		more = len(body) - cut
		body = body[:cut]
	}
	if clay.UI()({layout = {sizing = {grow(), fit()}, layoutDirection = .TopToBottom, padding = pad(10, 8)}, backgroundColor = COL_CODE_BG, cornerRadius = radius(8)}) {
		text(body, 13, col, FONT_MONO)
		if more > 0 do text(fmt.tprintf("… (%d more characters)", more), 12, COL_FAINT)
	}
}

thinking_view :: proc(m: ^Message, bi: int, blk: Block) {
	key := fmt.tprintf("think:%d:%d", m.uid, bi)
	open := app.expanded[key]
	id := clay.ID(key)
	if clay.UI(id)({layout = {sizing = {grow(), fixed(32)}, childGap = dpu(8), childAlignment = {y = .Center}, padding = pad(2, 0)}, backgroundColor = pressed(id) ? COL_CARD : {}, cornerRadius = radius(8)}) {
		icon(open ? .Chevron_Down : .Chevron_Right, 14, COL_FAINT)
		text("Thinking", 12.5, COL_FAINT, FONT_BOLD, .None)
		if !open do text_line(strings.trim_space(blk.text), 12.5, COL_FAINT)
	}
	if clicked(id) do toggle_expanded(key)
	if open {
		if clay.UI()({layout = {sizing = {grow(), fit()}, padding = {dpu(14), 0, 0, 0}}, border = {color = COL_BORDER, width = {left = dpu(2)}}}) {
			text(strings.trim_space(blk.text), 13, COL_THINK)
		}
	}
}

tool_view :: proc(name, summary, call_id, args: string, orphan: ^Message) {
	key := fmt.tprintf("tool:%s", call_id)
	open := app.expanded[key]
	result := orphan
	if result == nil do result = app.chat.results[call_id]
	status := 0
	if app.chat.running_tools[call_id] do status = 1
	else if result != nil do status = result.is_error ? 3 : 2
	hid := clay.ID(key)
	if clay.UI()({layout = {sizing = {grow(), fit()}, layoutDirection = .TopToBottom}, backgroundColor = COL_CARD, cornerRadius = radius(10)}) {
		if clay.UI(hid)({layout = {sizing = {grow(), fixed(40)}, childGap = dpu(8), childAlignment = {y = .Center}, padding = pad(10, 0)}, backgroundColor = pressed(hid) ? COL_CARD_HI : {}, cornerRadius = radius(10)}) {
			icon(open ? .Chevron_Down : .Chevron_Right, 14, COL_DIM)
			text(name, 14, COL_TEXT, FONT_BOLD, .None)
			if clay.UI()({layout = {sizing = {grow(), fit()}}, clip = {horizontal = true}}) do text(summary, 13, COL_DIM, FONT_MONO, .None)
			switch status {
			case 1: icon(.Spinner, 14, COL_WARN)
			case 2: icon(.Dot, 10, COL_OK)
			case 3: icon(.Dot, 10, COL_ERROR)
			case: icon(.Dot, 10, COL_FAINT)
			}
		}
		if open {
			if clay.UI()({layout = {sizing = {grow(), fit()}, layoutDirection = .TopToBottom, padding = {dpu(12), dpu(12), 0, dpu(12)}, childGap = dpu(6)}}) {
				if len(args) > 0 {
					section_label("INPUT")
					code_box(args, COL_TEXT)
				}
				out := result != nil ? message_plain_text(result) : (status == 1 ? "(running…)" : "")
				if len(out) > 0 {
					section_label(status == 3 ? "ERROR" : "OUTPUT")
					code_box(out, status == 3 ? COL_ERROR : COL_TEXT)
				}
			}
		}
	}
	if clicked(hid) do toggle_expanded(key)
}

toggle_expanded :: proc(key: string) {
	if v, ok := app.expanded[key]; ok do app.expanded[key] = !v
	else do app.expanded[strings.clone(key)] = true
}

// --- overlays ------------------------------------------------------------------------------

model_picker :: proc() {
	if clay.UI(clay.ID("picker"))({
		floating = {attachTo = .Root, zIndex = 50},
		layout = {sizing = {fixed(plat.w / ui.dp), fixed(plat.h / ui.dp)}, layoutDirection = .TopToBottom, padding = {0, 0, safe_top, 0}},
		backgroundColor = COL_BG,
	}) {
		back, _ := header("Choose model", "", true)
		if back {
			app.model_picker = false
			tf_blur()
			return
		}
		if clay.UI()({layout = {sizing = {grow(), fit()}, padding = pad(12, 12)}}) do text_field("filter", &app.model_filter, "Filter models", 15)
		filter := strings.to_lower(strings.trim_space(tf_text(&app.model_filter)), context.temp_allocator)
		if clay.UI(clay.ID("models"))({
			layout = {sizing = {grow(), grow()}, layoutDirection = .TopToBottom, padding = pad(12, 4), childGap = dpu(6)},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			if len(app.models) == 0 do text("No models available (configure providers in the web UI).", 14, COL_DIM)
			for m, i in app.models {
				if len(filter) > 0 && !strings.contains(strings.to_lower(fmt.tprintf("%s %s %s", m.name, m.id, m.provider), context.temp_allocator), filter) do continue
				id := clay.ID("model", u32(i))
				sel := m.id == app.chat.model_id && m.provider == app.chat.provider
				if clay.UI(id)({
					layout = {sizing = {grow(), fit()}, layoutDirection = .TopToBottom, padding = pad(14, 9), childGap = dpu(4)},
					backgroundColor = sel ? COL_USER : hover_col(id, COL_CARD, COL_CARD_HI),
					cornerRadius = radius(10),
				}) {
					text_line(len(m.name) > 0 ? m.name : m.id, 14.5, COL_TEXT, FONT_BOLD)
					text_line(fmt.tprintf("%s / %s", m.provider, m.id), 12, COL_DIM)
				}
				if clicked(id) {
					chat_set_model_remote(m)
					app.model_picker = false
					tf_blur()
				}
			}
		}
	}
	ui.tap = false
}

dialog :: proc() {
	d := &app.dialog
	if clay.UI()({
		floating = {attachTo = .Root, zIndex = 60},
		layout = {sizing = {fixed(plat.w / ui.dp), fixed(plat.h / ui.dp)}, childAlignment = {.Center, .Center}, padding = pad(16, 16)},
		backgroundColor = COL_SHADE,
	}) {
		if clay.UI()({
			layout = {sizing = {grow({max = dpx(460)}), fit({max = plat.h - dpx(32)})}, layoutDirection = .TopToBottom, padding = pad(18, 18), childGap = dpu(12)},
			backgroundColor = COL_PANEL,
			cornerRadius = radius(16),
		}) {
			text(d.title, 16.5, COL_TEXT, FONT_BOLD)
			if len(d.message) > 0 do text(d.message, 14, COL_DIM)
			switch d.method {
			case "select":
				if clay.UI(clay.ID("dlg-opts"))({layout = {sizing = {grow(), fit({max = plat.h * 0.5})}, layoutDirection = .TopToBottom, childGap = dpu(6)}, clip = {vertical = true, childOffset = clay.GetScrollOffset()}}) {
					for o, i in d.options {
						id := clay.ID("opt", u32(i))
						if clay.UI(id)({layout = {sizing = {grow(), fit({min = dpx(46)})}, padding = pad(14, 12)}, backgroundColor = hover_col(id, COL_CARD, COL_CARD_HI), cornerRadius = radius(10)}) do text(o, 14.5)
						if clicked(id) {
							dialog_respond(o, false, false)
							return
						}
					}
				}
				if button("dlg-cancel", "Cancel", COL_CARD, COL_TEXT) do dialog_respond("", false, true)
			case "confirm":
				if clay.UI()({layout = {sizing = {grow(), fit()}, childGap = dpu(10)}}) {
					if button("dlg-no", "Cancel", COL_CARD, COL_TEXT) do dialog_respond("", false, false)
					else if button("dlg-yes", "Confirm") do dialog_respond("", true, false)
				}
			case "input", "editor":
				d.field.multiline = d.method == "editor"
				submitted := text_field("dlg-field", &d.field, "", 15, d.method == "editor" ? 200 : 48)
				if clay.UI()({layout = {sizing = {grow(), fit()}, childGap = dpu(10)}}) {
					if button("dlg-cancel", "Cancel", COL_CARD, COL_TEXT) do dialog_respond("", false, true)
					else if button("dlg-ok", "OK") || submitted do dialog_respond(tf_text(&d.field), false, false)
				}
			}
		}
	}
	ui.tap = false
}

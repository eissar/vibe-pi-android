package main

// Application state, RPC message handling and screen logic.

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"

Screen :: enum {
	Connect,
	Sessions,
	New_Session,
	Chat,
}

Session_Item :: struct {
	id, name, first, cwd, modified: string,
	count:    int,
	mod_time: f64,
}

Model_Item :: struct {
	id, name, provider: string,
}

Dialog :: struct {
	active:    bool,
	id:        string,
	sid:       string,
	method:    string,
	title:     string,
	message:   string,
	options:   [dynamic]string,
	field:     Text_Field,
}

Chat :: struct {
	sid:           string,
	cwd:           string,
	title:         string,
	is_new:        bool,
	loading:       bool,
	running:       bool,
	phase:         string,
	messages:      [dynamic]^Message,
	streaming:     int, // index of in-progress assistant message, -1 none
	calls:         map[string]^Message, // tool call id -> message containing the call
	results:       map[string]^Message, // tool call id -> toolResult message
	running_tools: map[string]bool,
	composer:      Text_Field,
	scroll:        Scroll,
	stick_bottom:  bool,
	pending_prompt: string,
	provider:      string,
	model_id:      string,
	layout_w:      f32,
}

App :: struct {
	screen:          Screen,
	host_field:      Text_Field,
	token_field:     Text_Field,
	cwd_field:       Text_Field,
	model_filter:    Text_Field,
	connect_wanted:  bool,
	ever_connected:  bool,
	reconnect_at:    f64,
	reconnect_delay: f64,
	sessions:        [dynamic]Session_Item,
	sessions_arena:  virtual.Arena,
	sessions_loaded: bool,
	sessions_loading: bool,
	sessions_dirty_at: f64,
	running_ids:     map[string]bool,
	sessions_scroll: Scroll,
	recent_cwds:     [dynamic]string,
	default_cwd:     string,
	models:          [dynamic]Model_Item,
	models_arena:    virtual.Arena,
	default_model:   Model_Item,
	model_picker:    bool,
	model_scroll:    Scroll,
	new_scroll:      Scroll,
	chat:            Chat,
	expanded:        map[string]bool,
	toast_text:      string,
	toast_until:     f64,
	dialog:          Dialog,
	initialized:     bool,
}

app: App

// --- lifecycle ----------------------------------------------------------------

app_init :: proc() {
	if app.initialized do return // activity re-created: keep state & connection
	app.initialized = true
	app.chat.streaming = -1
	app.chat.composer.multiline = true
	app.token_field.secret = true
	app.dialog.field.multiline = true
	_ = virtual.arena_init_growing(&app.sessions_arena)
	_ = virtual.arena_init_growing(&app.models_arena)
	app_load_settings()
	if len(app.host_field.buf) == 0 do tf_set(&app.host_field, "10.0.2.2:7860")
	if app.connect_wanted do app_connect()
}

app_on_resume :: proc() {
	if app.connect_wanted && conn.state == .Closed {
		app.reconnect_delay = 0
		app.reconnect_at = now_ms()
	}
}

app_on_destroy :: proc() {
	app_save_settings()
}

settings_path :: proc() -> string {
	return concat(plat.data_dir, "/settings.txt")
}

app_load_settings :: proc() {
	data, ok := read_file(settings_path(), context.temp_allocator)
	if !ok do return
	s := string(data)
	for line in strings.split_lines_iterator(&s) {
		i := strings.index_byte(line, '=')
		if i < 0 do continue
		k, v := line[:i], line[i + 1:]
		switch k {
		case "host":
			tf_set(&app.host_field, v)
		case "token":
			tf_set(&app.token_field, v)
		case "cwd":
			tf_set(&app.cwd_field, v)
		case "auto":
			app.connect_wanted = v == "1"
		}
	}
}

app_save_settings :: proc() {
	if plat.data_dir == "" do return
	s := fmt.tprintf("host=%s\ntoken=%s\ncwd=%s\nauto=%s\n",
		tf_text(&app.host_field), tf_text(&app.token_field), tf_text(&app.cwd_field), app.connect_wanted ? "1" : "0")
	write_file(settings_path(), transmute([]u8)s)
}

toast :: proc(msg: string) {
	delete(app.toast_text)
	app.toast_text = strings.clone(msg)
	app.toast_until = now_ms() + 3200
	request_redraw(3300)
}

// --- connection -------------------------------------------------------------------

app_connect :: proc() {
	host, port, path, ok := parse_address(tf_text(&app.host_field))
	if !ok {
		toast("Invalid server address")
		return
	}
	token := strings.trim_space(tf_text(&app.token_field))
	if len(token) > 0 && !strings.contains(path, "token=") {
		path = fmt.tprintf("%s%stoken=%s", path, strings.contains(path, "?") ? "&" : "?", token)
	}
	app.connect_wanted = true
	if !net_connect(&conn, host, port, path) {
		app_on_disconnected()
	}
}

app_disconnect :: proc() {
	app.connect_wanted = false
	app.reconnect_at = 0
	net_close(&conn, "")
	rpc_clear_pending()
	app.screen = .Connect
	app_save_settings()
}

app_on_connected :: proc() {
	app.ever_connected = true
	app.reconnect_delay = 0
	app.reconnect_at = 0
	app_save_settings()
	rpc_subscribe("agent.events")
	rpc_subscribe("agent.running")
	rpc_subscribe("sessions.changed")
	rpc_call("sessions.list", "", .Sessions_List)
	rpc_call("models.list", "", .Models_List)
	rpc_call("system.defaultCwd", "", .Default_Cwd)
	if app.screen == .Connect do app.screen = .Sessions
	if app.screen == .Chat && len(app.chat.sid) > 0 do chat_reload()
}

app_on_disconnected :: proc() {
	rpc_clear_pending()
	app.chat.loading = false
	app.sessions_loading = false
	if app.connect_wanted {
		app.reconnect_delay = clamp(app.reconnect_delay * 2, 1000, 15000)
		app.reconnect_at = now_ms() + app.reconnect_delay
		request_redraw(app.reconnect_delay + 10)
	}
	if !app.ever_connected && len(conn.error) > 0 && app.screen == .Connect {
		// first attempt failed: stay on the connect screen without retry loop
		app.connect_wanted = false
		app.reconnect_at = 0
	}
}

app_tick :: proc() {
	t := now_ms()
	if app.reconnect_at > 0 && t >= app.reconnect_at && conn.state == .Closed && app.connect_wanted {
		app.reconnect_at = 0
		app_connect()
	}
	if app.sessions_dirty_at > 0 && t >= app.sessions_dirty_at && !app.sessions_loading && conn.state == .Open {
		app.sessions_dirty_at = 0
		app.sessions_loading = true
		rpc_call("sessions.list", "", .Sessions_List)
	}
}

// --- incoming messages ------------------------------------------------------------

scratch_arena: virtual.Arena
scratch_ready: bool

app_on_message :: proc(text: string) {
	if !scratch_ready {
		_ = virtual.arena_init_growing(&scratch_arena)
		scratch_ready = true
	}
	alloc := virtual.arena_allocator(&scratch_arena)
	defer virtual.arena_free_all(&scratch_arena)
	v, err := json.parse_string(text, .JSON, false, alloc)
	if err != .None do return
	switch jstr(jget(v, "kind")) {
	case "response":
		id := jstr(jget(v, "id"))
		p, ok := rpc_pending[id]
		if !ok do return
		key := id
		for k in rpc_pending do if k == id {key = k; break}
		delete_key(&rpc_pending, id)
		defer {delete(key); delete(p.tag)}
		if !jbool(jget(v, "ok")) {
			e := jget(v, "error")
			on_rpc_error(p, jstr(jget(e, "message")), jstr(jget(e, "code")))
			return
		}
		on_rpc_result(p, jget(v, "result"))
	case "event":
		on_event(jstr(jget(v, "topic")), jstr(jget(v, "key")), jget(v, "data"))
	}
}

on_rpc_error :: proc(p: Pending, msg, code: string) {
	#partial switch p.kind {
	case .Session_Get:
		app.chat.loading = false
	case .Sessions_List:
		app.sessions_loading = false
	case .Agent_New, .Prompt:
		app.chat.running = false
		app.chat.phase = ""
	}
	toast(len(msg) > 0 ? msg : code)
}

on_rpc_result :: proc(p: Pending, r: json.Value) {
	switch p.kind {
	case .None, .Generic, .Abort:
	case .Sessions_List:
		app.sessions_loading = false
		app.sessions_loaded = true
		set_sessions(jarr(jget(r, "sessions")))
		clear_running()
		for id in jarr(jget(r, "runningSessionIds")) do app.running_ids[strings.clone(jstr(id))] = true
	case .Session_Get:
		if p.tag != app.chat.sid do return
		ctx := jget(r, "context")
		chat_set_messages(jarr(jget(ctx, "messages")))
		model := jget(ctx, "model")
		chat_set_model(jstr(jget(model, "provider")), jstr(jget(model, "modelId")))
		info := jget(r, "info")
		if name := jstr(jget(info, "name")); len(name) > 0 do chat_set_title(name)
		else if first := jstr(jget(info, "firstMessage")); len(first) > 0 do chat_set_title(first)
		if cwd := jstr(jget(info, "cwd")); len(cwd) > 0 {
			delete(app.chat.cwd)
			app.chat.cwd = strings.clone(cwd)
		}
		st := jget(r, "agentState")
		state := jget(st, "state")
		app.chat.running = jbool(jget(st, "running")) && (jbool(jget(state, "isStreaming")) || jbool(jget(state, "isPromptRunning"))) || app.running_ids[app.chat.sid]
		app.chat.phase = app.chat.running ? "Working…" : ""
		app.chat.loading = false
		app.chat.stick_bottom = true
	case .Default_Cwd:
		delete(app.default_cwd)
		app.default_cwd = strings.clone(jstr(jget(r, "cwd")))
		if len(app.cwd_field.buf) == 0 do tf_set(&app.cwd_field, app.default_cwd)
	case .Agent_New:
		sid := jstr(jget(r, "sessionId"))
		if len(sid) == 0 do return
		delete(app.chat.sid)
		app.chat.sid = strings.clone(sid)
		app.chat.is_new = false
		if len(app.chat.pending_prompt) > 0 {
			send_prompt(app.chat.pending_prompt)
			delete(app.chat.pending_prompt)
			app.chat.pending_prompt = ""
		}
	case .Prompt:
	case .Models_List:
		virtual.arena_free_all(&app.models_arena)
		clear(&app.models)
		a := virtual.arena_allocator(&app.models_arena)
		for mv in jarr(jget(r, "models")) {
			append(&app.models, Model_Item {
				id = strings.clone(jstr(jget(mv, "id")), a),
				name = strings.clone(jstr(jget(mv, "name")), a),
				provider = strings.clone(jstr(jget(mv, "provider")), a),
			})
		}
		dm := jget(r, "defaultModel")
		app.default_model = Model_Item {
			id       = strings.clone(jstr(jget(dm, "modelId")), a),
			provider = strings.clone(jstr(jget(dm, "provider")), a),
		}
		if app.chat.is_new && len(app.chat.model_id) == 0 do chat_set_model(app.default_model.provider, app.default_model.id)
	case .Set_Model:
		toast("Model updated")
	case .Rename, .Delete:
		app.sessions_dirty_at = now_ms()
	}
}

clear_running :: proc() {
	for k in app.running_ids do delete(k)
	clear(&app.running_ids)
}

set_sessions :: proc(arr: json.Array) {
	virtual.arena_free_all(&app.sessions_arena)
	clear(&app.sessions)
	clear(&app.recent_cwds)
	a := virtual.arena_allocator(&app.sessions_arena)
	for s in arr {
		it := Session_Item {
			id       = strings.clone(jstr(jget(s, "id")), a),
			name     = strings.clone(jstr(jget(s, "name")), a),
			first    = strings.clone(jstr(jget(s, "firstMessage")), a),
			cwd      = strings.clone(jstr(jget(s, "cwd")), a),
			modified = strings.clone(jstr(jget(s, "modified")), a),
			count    = int(jnum(jget(s, "messageCount"))),
		}
		it.mod_time = parse_iso_time(it.modified)
		append(&app.sessions, it)
	}
	slice.sort_by(app.sessions[:], proc(x, y: Session_Item) -> bool {return x.mod_time > y.mod_time})
	seen := make(map[string]bool, 16, context.temp_allocator)
	for s in app.sessions {
		if len(s.cwd) == 0 || seen[s.cwd] do continue
		seen[s.cwd] = true
		append(&app.recent_cwds, s.cwd)
	}
}

on_event :: proc(topic, key: string, data: json.Value) {
	switch topic {
	case "agent.events":
		if app.screen == .Chat && len(app.chat.sid) > 0 && key == app.chat.sid do chat_on_agent_event(data)
	case "agent.running":
		clear_running()
		for id in jarr(jget(data, "sessionIds")) do app.running_ids[strings.clone(jstr(id))] = true
		if len(app.chat.sid) > 0 {
			was := app.chat.running
			now := app.running_ids[app.chat.sid]
			if was && !now {
				app.chat.running = false
				app.chat.phase = ""
				clear(&app.chat.running_tools)
			} else if !was && now {
				app.chat.running = true
				if app.chat.phase == "" do app.chat.phase = "Working…"
			}
		}
	case "sessions.changed":
		if app.sessions_dirty_at == 0 do app.sessions_dirty_at = now_ms() + 600
		request_redraw(650)
	}
}

// --- chat state ------------------------------------------------------------------------

chat_clear_messages :: proc() {
	for m in app.chat.messages do message_free(m)
	clear(&app.chat.messages)
	clear(&app.chat.calls)
	clear(&app.chat.results)
	clear(&app.chat.running_tools)
	app.chat.streaming = -1
}

chat_index_message :: proc(m: ^Message) {
	for b in m.blocks do if b.kind == .Tool_Call && len(b.call_id) > 0 do app.chat.calls[b.call_id] = m
	if m.role == .Tool_Result && len(m.tool_call_id) > 0 {
		app.chat.results[m.tool_call_id] = m
		if owner, ok := app.chat.calls[m.tool_call_id]; ok do owner.dirty = true
	}
}

chat_unindex_message :: proc(m: ^Message) {
	for b in m.blocks do if b.kind == .Tool_Call && app.chat.calls[b.call_id] == m do delete_key(&app.chat.calls, b.call_id)
	if m.role == .Tool_Result && app.chat.results[m.tool_call_id] == m do delete_key(&app.chat.results, m.tool_call_id)
}

chat_set_messages :: proc(arr: json.Array) {
	chat_clear_messages()
	for v in arr {
		role := jstr(jget(v, "role"))
		if role == "system" do continue
		if role == "custom" && !jbool(jget(v, "display")) do continue
		m := message_from_json(v)
		append(&app.chat.messages, m)
		chat_index_message(m)
	}
	for m in app.chat.messages do m.dirty = true
}

chat_append :: proc(m: ^Message) {
	append(&app.chat.messages, m)
	chat_index_message(m)
}

chat_replace :: proc(idx: int, m: ^Message) {
	old := app.chat.messages[idx]
	chat_unindex_message(old)
	message_free(old)
	app.chat.messages[idx] = m
	chat_index_message(m)
	// results referencing calls in this message must re-render inside it
}

chat_set_title :: proc(t: string) {
	delete(app.chat.title)
	line := strings.trim_space(t)
	if i := strings.index_byte(line, '\n'); i >= 0 do line = line[:i]
	app.chat.title = strings.clone(line)
}

chat_set_model :: proc(provider, id: string) {
	delete(app.chat.provider)
	delete(app.chat.model_id)
	app.chat.provider = strings.clone(provider)
	app.chat.model_id = strings.clone(id)
}

model_label :: proc() -> string {
	if len(app.chat.model_id) == 0 do return "default model"
	for m in app.models {
		if m.id == app.chat.model_id && m.provider == app.chat.provider && len(m.name) > 0 do return m.name
	}
	return app.chat.model_id
}

open_session :: proc(s: Session_Item) {
	chat_clear_messages()
	delete(app.chat.sid)
	app.chat.sid = strings.clone(s.id)
	delete(app.chat.cwd)
	app.chat.cwd = strings.clone(s.cwd)
	chat_set_title(len(s.name) > 0 ? s.name : s.first)
	app.chat.is_new = false
	app.chat.running = app.running_ids[s.id]
	app.chat.phase = app.chat.running ? "Working…" : ""
	app.chat.scroll = {}
	app.chat.stick_bottom = true
	chat_set_model("", "")
	app.screen = .Chat
	chat_reload()
}

chat_reload :: proc() {
	if len(app.chat.sid) == 0 do return
	app.chat.loading = true
	w: Jw
	jw_begin(&w)
	jw_s(&w, "id", app.chat.sid)
	jw_bool(&w, "includeState", true)
	jw_raw(&w, "historyWindow", `{"maxTurns":80}`)
	rpc_call("sessions.get", jw_end(&w), .Session_Get, app.chat.sid)
}

start_new_session :: proc(cwd: string) {
	chat_clear_messages()
	delete(app.chat.sid)
	app.chat.sid = ""
	delete(app.chat.cwd)
	app.chat.cwd = strings.clone(strings.trim_space(cwd))
	chat_set_title("New session")
	app.chat.is_new = true
	app.chat.running = false
	app.chat.phase = ""
	app.chat.scroll = {}
	app.chat.stick_bottom = true
	chat_set_model(app.default_model.provider, app.default_model.id)
	app.screen = .Chat
	tf_focus(&app.chat.composer)
}

send_prompt :: proc(text: string) {
	cmd: Jw
	jw_begin(&cmd)
	jw_s(&cmd, "type", "prompt")
	jw_s(&cmd, "message", text)
	if app.chat.running do jw_s(&cmd, "streamingBehavior", "followUp")
	w: Jw
	jw_begin(&w)
	jw_s(&w, "sessionId", app.chat.sid)
	jw_raw(&w, "command", jw_end(&cmd))
	rpc_call("agent.command", jw_end(&w), .Prompt)
}

chat_send :: proc() {
	text := strings.trim_space(tf_text(&app.chat.composer))
	if len(text) == 0 do return
	if conn.state != .Open {
		toast("Not connected")
		return
	}
	// optimistic user bubble
	m := new(Message)
	msg_uid_counter += 1
	m.uid = msg_uid_counter
	m.role = .User
	m.dirty = true
	owned := strings.clone(text)
	append(&m.strs, owned)
	append(&m.blocks, Block{kind = .Text, text = owned})
	chat_append(m)
	app.chat.stick_bottom = true

	if len(app.chat.sid) == 0 {
		app.chat.pending_prompt = strings.clone(text)
		w: Jw
		jw_begin(&w)
		jw_s(&w, "cwd", app.chat.cwd)
		jw_s(&w, "type", "ensure_session")
		if len(app.chat.model_id) > 0 {
			jw_s(&w, "provider", app.chat.provider)
			jw_s(&w, "modelId", app.chat.model_id)
		}
		rpc_call("agent.new", jw_end(&w), .Agent_New)
		tf_set(&app.cwd_field, app.chat.cwd)
	} else {
		send_prompt(text)
	}
	if !app.chat.running {
		app.chat.running = true
		app.chat.phase = "Thinking…"
	}
	tf_set(&app.chat.composer, "")
}

chat_abort :: proc() {
	if len(app.chat.sid) == 0 do return
	w: Jw
	jw_begin(&w)
	jw_s(&w, "sessionId", app.chat.sid)
	jw_raw(&w, "command", `{"type":"abort"}`)
	rpc_call("agent.command", jw_end(&w), .Abort)
	app.chat.phase = "Stopping…"
}

chat_set_model_remote :: proc(m: Model_Item) {
	chat_set_model(m.provider, m.id)
	if len(app.chat.sid) == 0 do return
	cmd: Jw
	jw_begin(&cmd)
	jw_s(&cmd, "type", "set_model")
	jw_s(&cmd, "provider", m.provider)
	jw_s(&cmd, "modelId", m.id)
	w: Jw
	jw_begin(&w)
	jw_s(&w, "sessionId", app.chat.sid)
	jw_raw(&w, "command", jw_end(&cmd))
	rpc_call("agent.command", jw_end(&w), .Set_Model)
}

chat_on_agent_event :: proc(ev: json.Value) {
	c := &app.chat
	t := jstr(jget(ev, "type"))
	switch t {
	case "agent_start":
		c.running = true
		if c.phase == "" || c.phase == "Stopping…" do c.phase = "Thinking…"
	case "message_start", "message_update":
		msg := jget(ev, "message")
		if jstr(jget(msg, "role")) != "assistant" do return
		m := message_from_json(msg)
		if c.streaming >= 0 && c.streaming < len(c.messages) {
			chat_replace(c.streaming, m)
		} else {
			chat_append(m)
			c.streaming = len(c.messages) - 1
		}
		c.phase = ""
	case "message_end":
		msg := jget(ev, "message")
		role := jstr(jget(msg, "role"))
		switch role {
		case "system":
			return
		case "user":
			txt := strings.trim_space(user_text_of_json(msg))
			// skip if it is our optimistic bubble
			for i := len(c.messages) - 1; i >= max(0, len(c.messages) - 3); i -= 1 {
				lm := c.messages[i]
				if lm.role == .User && len(lm.blocks) > 0 && strings.trim_space(lm.blocks[0].text) == txt do return
			}
			chat_append(message_from_json(msg))
		case "assistant":
			m := message_from_json(msg)
			if c.streaming >= 0 && c.streaming < len(c.messages) do chat_replace(c.streaming, m)
			else do chat_append(m)
			c.streaming = -1
			c.phase = "Working…"
		case "custom":
			if jbool(jget(msg, "display")) do chat_append(message_from_json(msg))
		case:
			chat_append(message_from_json(msg))
		}
	case "tool_execution_start":
		id := jstr(jget(ev, "toolCallId"))
		if len(id) > 0 {
			c.running_tools[strings.clone(id)] = true
			if owner, ok := c.calls[id]; ok do owner.dirty = true
		}
		c.phase = strings.clone(fmt.tprintf("Running %s…", jstr(jget(ev, "toolName"))))
		phase_own(c.phase)
	case "tool_execution_end":
		id := jstr(jget(ev, "toolCallId"))
		for k in c.running_tools {
			if k == id {
				delete_key(&c.running_tools, k)
				delete(k)
				break
			}
		}
		if owner, ok := c.calls[id]; ok do owner.dirty = true
		c.phase = "Working…"
	case "prompt_done":
		c.running = false
		c.phase = ""
	case "prompt_error":
		c.running = false
		c.phase = ""
		toast(jstr(jget(ev, "errorMessage")))
	case "auto_retry_start":
		c.phase = "Retrying…"
	case "compaction_start", "auto_compaction_start":
		c.phase = "Compacting context…"
	case "compaction_end", "auto_compaction_end":
		c.phase = c.running ? "Working…" : ""
		chat_reload()
	case "extension_error":
		toast(jstr(jget(ev, "error")))
	case "extension_ui_request":
		on_extension_ui(ev)
	}
}

// Keep exactly one heap-allocated dynamic phase string alive.
@(private = "file")
phase_owned: string
@(private = "file")
phase_own :: proc(s: string) {
	if len(phase_owned) > 0 && phase_owned != s do delete(phase_owned)
	phase_owned = s
}

on_extension_ui :: proc(ev: json.Value) {
	method := jstr(jget(ev, "method"))
	switch method {
	case "notify":
		toast(jstr(jget(ev, "message")))
	case "select", "confirm", "input", "editor":
		d := &app.dialog
		dialog_reset()
		d.active = true
		d.id = strings.clone(jstr(jget(ev, "id")))
		d.sid = strings.clone(app.chat.sid)
		d.method = strings.clone(method)
		d.title = strings.clone(jstr(jget(ev, "title")))
		d.message = strings.clone(jstr(jget(ev, "message")))
		for o in jarr(jget(ev, "options")) do append(&d.options, strings.clone(jstr(o)))
		if method == "editor" do tf_set(&d.field, jstr(jget(ev, "prefill")))
		if method == "input" || method == "editor" do tf_focus(&d.field)
	}
}

dialog_reset :: proc() {
	d := &app.dialog
	delete(d.id); delete(d.sid); delete(d.method); delete(d.title); delete(d.message)
	for o in d.options do delete(o)
	clear(&d.options)
	d.id, d.sid, d.method, d.title, d.message = "", "", "", "", ""
	tf_set(&d.field, "")
	d.active = false
}

// value: "" + cancelled=true, or confirmed, or value
dialog_respond :: proc(value: string, confirmed: bool, cancelled: bool) {
	d := &app.dialog
	cmd: Jw
	jw_begin(&cmd)
	jw_s(&cmd, "type", "extension_ui_response")
	jw_s(&cmd, "id", d.id)
	if cancelled do jw_bool(&cmd, "cancelled", true)
	else if d.method == "confirm" do jw_bool(&cmd, "confirmed", confirmed)
	else do jw_s(&cmd, "value", value)
	w: Jw
	jw_begin(&w)
	jw_s(&w, "sessionId", d.sid)
	jw_raw(&w, "command", jw_end(&cmd))
	rpc_call("agent.command", jw_end(&w), .Generic)
	dialog_reset()
	tf_blur()
}

// --- navigation ----------------------------------------------------------------------

app_can_go_back :: proc() -> bool {
	if app.dialog.active || app.model_picker do return true
	return app.screen == .Chat || app.screen == .New_Session
}

app_back :: proc() -> bool {
	if app.dialog.active {
		dialog_respond("", false, true)
		return true
	}
	if app.model_picker {
		app.model_picker = false
		tf_blur()
		return true
	}
	switch app.screen {
	case .Chat:
		tf_blur()
		app.screen = .Sessions
		app.sessions_dirty_at = now_ms()
		return true
	case .New_Session:
		tf_blur()
		app.screen = .Sessions
		return true
	case .Sessions, .Connect:
	}
	return false
}

app_hotkey_send :: proc() {
	if app.screen == .Chat && ui.focus == &app.chat.composer do chat_send()
}

// --- time helpers ---------------------------------------------------------------------

// ISO-8601 "YYYY-MM-DDTHH:MM:SS(.sss)Z" -> unix seconds.
parse_iso_time :: proc(s: string) -> f64 {
	num :: proc(s: string, a, b: int) -> int {
		v := 0
		if b > len(s) do return 0
		for i in a ..< b {
			if s[i] < '0' || s[i] > '9' do return 0
			v = v * 10 + int(s[i] - '0')
		}
		return v
	}
	if len(s) < 19 do return 0
	y := num(s, 0, 4)
	mo := num(s, 5, 7)
	d := num(s, 8, 10)
	h := num(s, 11, 13)
	mi := num(s, 14, 16)
	se := num(s, 17, 19)
	// days from civil (Howard Hinnant)
	yy := mo <= 2 ? y - 1 : y
	era := (yy >= 0 ? yy : yy - 399) / 400
	yoe := yy - era * 400
	mp := (mo + 9) % 12
	doy := (153 * mp + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	days := era * 146097 + doe - 719468
	return f64(days) * 86400 + f64(h * 3600 + mi * 60 + se)
}

unix_now :: proc() -> f64 {
	ts: timespec
	clock_gettime(0, &ts) // CLOCK_REALTIME
	return f64(ts.tv_sec)
}

relative_time :: proc(t: f64) -> string {
	if t <= 0 do return ""
	d := unix_now() - t
	switch {
	case d < 60:
		return "just now"
	case d < 3600:
		return fmt.tprintf("%dm ago", int(d / 60))
	case d < 86400:
		return fmt.tprintf("%dh ago", int(d / 3600))
	case d < 86400 * 30:
		return fmt.tprintf("%dd ago", int(d / 86400))
	}
	return fmt.tprintf("%dmo ago", int(d / (86400 * 30)))
}

path_base :: proc(p: string) -> string {
	s := strings.trim_right(p, "/")
	if i := strings.last_index_byte(s, '/'); i >= 0 do return s[i + 1:]
	return s
}

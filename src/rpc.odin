package main

// JSON helpers, the Pi WebUI RPC wire protocol, and conversion of Pi agent
// messages into the app's display model.

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

// --- JSON reading ------------------------------------------------------------

jget :: proc(v: json.Value, key: string) -> json.Value {
	if o, ok := v.(json.Object); ok do return o[key]
	return nil
}
jstr :: proc(v: json.Value) -> string {
	s, _ := v.(json.String)
	return s
}
jnum :: proc(v: json.Value) -> f64 {
	#partial switch x in v {
	case json.Float:
		return f64(x)
	case json.Integer:
		return f64(x)
	}
	return 0
}
jbool :: proc(v: json.Value) -> bool {
	b, _ := v.(json.Boolean)
	return bool(b)
}
jarr :: proc(v: json.Value) -> json.Array {
	a, _ := v.(json.Array)
	return a
}

// --- JSON writing ------------------------------------------------------------

jw_str :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i := 0; i < len(s); i += 1 {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			if ch < 0x20 {
				fmt.sbprintf(b, "\\u%04x", ch)
			} else {
				strings.write_byte(b, ch)
			}
		}
	}
	strings.write_byte(b, '"')
}

// Compact JSON object writer: obj("k", value, ...) where values are pre-encoded.
Jw :: struct {
	b:     strings.Builder,
	first: bool,
}
jw_begin :: proc(w: ^Jw) {
	w.b = strings.builder_make(context.temp_allocator)
	strings.write_byte(&w.b, '{')
	w.first = true
}
@(private = "file")
jw_key :: proc(w: ^Jw, k: string) {
	if !w.first do strings.write_byte(&w.b, ',')
	w.first = false
	jw_str(&w.b, k)
	strings.write_byte(&w.b, ':')
}
jw_s :: proc(w: ^Jw, k, v: string) {jw_key(w, k); jw_str(&w.b, v)}
jw_raw :: proc(w: ^Jw, k, v: string) {jw_key(w, k); strings.write_string(&w.b, v)}
jw_bool :: proc(w: ^Jw, k: string, v: bool) {jw_key(w, k); strings.write_string(&w.b, v ? "true" : "false")}
jw_int :: proc(w: ^Jw, k: string, v: int) {jw_key(w, k); strings.write_int(&w.b, v)}
jw_end :: proc(w: ^Jw) -> string {
	strings.write_byte(&w.b, '}')
	return strings.to_string(w.b)
}

// Pretty-print a JSON value (for tool arguments).
json_pretty :: proc(b: ^strings.Builder, v: json.Value, indent := 0) {
	pad :: proc(b: ^strings.Builder, n: int) {for _ in 0 ..< n do strings.write_string(b, "  ")}
	switch x in v {
	case json.Null:
		strings.write_string(b, "null")
	case json.Integer:
		strings.write_i64(b, x)
	case json.Float:
		buf: [64]u8
		f := f64(x)
		if f == f64(i64(f)) && abs(f) < 1e15 do strings.write_i64(b, i64(f))
		else do strings.write_string(b, strconv.write_float(buf[:], f, 'g', -1, 64))
	case json.Boolean:
		strings.write_string(b, x ? "true" : "false")
	case json.String:
		// multi-line strings are shown raw for readability
		if strings.contains_rune(x, '\n') && indent > 0 {
			strings.write_string(b, "|\n")
			rest := string(x)
			for line in strings.split_lines_iterator(&rest) {
				pad(b, indent + 1)
				strings.write_string(b, line)
				strings.write_byte(b, '\n')
			}
			pad(b, indent)
		} else {
			jw_str(b, x)
		}
	case json.Array:
		if len(x) == 0 {strings.write_string(b, "[]"); return}
		strings.write_string(b, "[\n")
		for e, i in x {
			pad(b, indent + 1)
			json_pretty(b, e, indent + 1)
			if i < len(x) - 1 do strings.write_byte(b, ',')
			strings.write_byte(b, '\n')
		}
		pad(b, indent)
		strings.write_byte(b, ']')
	case json.Object:
		if len(x) == 0 {strings.write_string(b, "{}"); return}
		strings.write_string(b, "{\n")
		i := 0
		for k, e in x {
			pad(b, indent + 1)
			strings.write_string(b, k)
			strings.write_string(b, ": ")
			json_pretty(b, e, indent + 1)
			if i < len(x) - 1 do strings.write_byte(b, ',')
			strings.write_byte(b, '\n')
			i += 1
		}
		pad(b, indent)
		strings.write_byte(b, '}')
	case:
		strings.write_string(b, "null")
	}
}

// --- RPC --------------------------------------------------------------------

Req_Kind :: enum {
	None,
	Sessions_List,
	Session_Get,
	Default_Cwd,
	Agent_New,
	Prompt,
	Abort,
	Models_List,
	Set_Model,
	Rename,
	Delete,
	Generic,
}

Pending :: struct {
	kind: Req_Kind,
	tag:  string,
}

rpc_pending: map[string]Pending
rpc_next_id: int

rpc_call :: proc(method: string, params: string, kind: Req_Kind, tag := "") -> bool {
	if conn.state != .Open do return false
	rpc_next_id += 1
	id := fmt.aprintf("a%d", rpc_next_id)
	w: Jw
	jw_begin(&w)
	jw_s(&w, "kind", "request")
	jw_s(&w, "id", id)
	jw_s(&w, "method", method)
	if len(params) > 0 do jw_raw(&w, "params", params)
	msg := jw_end(&w)
	rpc_pending[id] = Pending{kind, strings.clone(tag)}
	return net_send_text(&conn, msg)
}

rpc_subscribe :: proc(topic: string, key := "*") {
	rpc_next_id += 1
	w: Jw
	jw_begin(&w)
	jw_s(&w, "kind", "subscribe")
	jw_s(&w, "id", fmt.tprintf("s%d", rpc_next_id))
	jw_s(&w, "topic", topic)
	jw_s(&w, "key", key)
	net_send_text(&conn, jw_end(&w))
}

rpc_clear_pending :: proc() {
	for k, p in rpc_pending {
		delete(k)
		delete(p.tag)
	}
	clear(&rpc_pending)
}

// --- Display model ------------------------------------------------------------

Role :: enum {
	User,
	Assistant,
	Tool_Result,
	Custom,
	Other,
}

Block_Kind :: enum {
	Text,
	Thinking,
	Tool_Call,
	Image,
	Error,
}

Block :: struct {
	kind:    Block_Kind,
	text:    string, // text / thinking / pretty args
	name:    string, // tool name
	summary: string, // tool one-line summary
	call_id: string,
}

Message :: struct {
	uid:          int,
	role:         Role,
	blocks:       [dynamic]Block,
	tool_call_id: string,
	tool_name:    string,
	is_error:     bool,
	label:        string, // for custom/other roles
	strs:         [dynamic]string, // owned allocations
	parts:        [dynamic]Part,   // markdown split of text blocks (lazy)
	parsed:       bool,
}

Part_Kind :: enum {
	Para,
	Code,
	Heading,
}

Part :: struct {
	kind:  Part_Kind,
	text:  string, // slice of a block's text (or owned when rewritten)
	block: int,
}

msg_uid_counter: int

@(private = "file")
own :: proc(m: ^Message, s: string) -> string {
	if len(s) == 0 do return ""
	c := strings.clone(s)
	append(&m.strs, c)
	return c
}

message_free :: proc(m: ^Message) {
	if m == nil do return
	for s in m.strs do delete(s)
	delete(m.strs)
	delete(m.blocks)
	delete(m.parts)
	free(m)
}

message_plain_text :: proc(m: ^Message, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for blk in m.blocks {
		#partial switch blk.kind {
		case .Text, .Error:
			if strings.builder_len(b) > 0 do strings.write_string(&b, "\n\n")
			strings.write_string(&b, blk.text)
		case .Tool_Call:
			if strings.builder_len(b) > 0 do strings.write_string(&b, "\n\n")
			strings.write_string(&b, blk.text)
		}
	}
	return strings.to_string(b)
}

tool_summary :: proc(name: string, args: json.Value) -> string {
	for key in ([]string{"command", "path", "file_path", "filePath", "pattern", "query", "url", "task", "prompt"}) {
		if s := jstr(jget(args, key)); len(s) > 0 {
			line := s
			if i := strings.index_byte(line, '\n'); i >= 0 do line = line[:i]
			return line
		}
	}
	if o, ok := args.(json.Object); ok {
		for _, v in o {
			if s := jstr(v); len(s) > 0 {
				line := s
				if i := strings.index_byte(line, '\n'); i >= 0 do line = line[:i]
				return line
			}
		}
	}
	return ""
}

message_from_json :: proc(v: json.Value) -> ^Message {
	role := jstr(jget(v, "role"))
	m := new(Message)
	msg_uid_counter += 1
	m.uid = msg_uid_counter
	switch role {
	case "user":
		m.role = .User
	case "assistant":
		m.role = .Assistant
	case "toolResult":
		m.role = .Tool_Result
		m.tool_call_id = own(m, jstr(jget(v, "toolCallId")))
		m.tool_name = own(m, jstr(jget(v, "toolName")))
		m.is_error = jbool(jget(v, "isError"))
	case "custom":
		m.role = .Custom
		m.label = own(m, jstr(jget(v, "customType")))
	case "bashExecution":
		m.role = .Other
		m.label = "bash"
		cmd := jstr(jget(v, "command"))
		out := jstr(jget(v, "output"))
		append(&m.blocks, Block{kind = .Text, text = own(m, fmt.tprintf("$ %s\n%s", cmd, out))})
		return m
	case:
		m.role = .Other
		m.label = own(m, role)
	}

	content := jget(v, "content")
	#partial switch c in content {
	case json.String:
		append(&m.blocks, Block{kind = .Text, text = own(m, c)})
	case json.Array:
		for part in c {
			t := jstr(jget(part, "type"))
			switch t {
			case "text":
				txt := jstr(jget(part, "text"))
				if len(strings.trim_space(txt)) > 0 do append(&m.blocks, Block{kind = .Text, text = own(m, txt)})
			case "thinking":
				txt := jstr(jget(part, "thinking"))
				if len(strings.trim_space(txt)) > 0 do append(&m.blocks, Block{kind = .Thinking, text = own(m, txt)})
			case "toolCall", "tool_use":
				args := jget(part, "arguments")
				if args == nil do args = jget(part, "input")
				b := strings.builder_make(context.temp_allocator)
				if s, is_str := args.(json.String); is_str {
					strings.write_string(&b, s)
				} else {
					json_pretty(&b, args)
				}
				name := jstr(jget(part, "name"))
				append(&m.blocks, Block {
					kind    = .Tool_Call,
					name    = own(m, name),
					call_id = own(m, jstr(jget(part, "id"))),
					summary = own(m, tool_summary(name, args)),
					text    = own(m, strings.to_string(b)),
				})
			case "image":
				append(&m.blocks, Block{kind = .Image, text = "[image]"})
			}
		}
	}
	if m.role == .Assistant {
		em := jstr(jget(v, "errorMessage"))
		stop := jstr(jget(v, "stopReason"))
		if len(em) > 0 {
			append(&m.blocks, Block{kind = .Error, text = own(m, em)})
		} else if stop == "aborted" {
			append(&m.blocks, Block{kind = .Error, text = "Aborted"})
		}
	}
	return m
}

// Text of a user message (for de-duplicating optimistic bubbles).
user_text_of_json :: proc(v: json.Value) -> string {
	content := jget(v, "content")
	#partial switch c in content {
	case json.String:
		return c
	case json.Array:
		for part in c {
			if jstr(jget(part, "type")) == "text" do return jstr(jget(part, "text"))
		}
	}
	return ""
}

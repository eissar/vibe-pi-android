package main

// EGL + OpenGL ES 2.0 bindings (only what we use) and a batched 2D renderer.

import "core:c"

foreign import libegl "system:EGL"
foreign import libgles "system:GLESv2"

EGLDisplay :: rawptr
EGLSurface :: rawptr
EGLContext :: rawptr
EGLConfig  :: rawptr

EGL_DEFAULT_DISPLAY     :: 0
EGL_NONE                :: 0x3038
EGL_RED_SIZE            :: 0x3024
EGL_GREEN_SIZE          :: 0x3023
EGL_BLUE_SIZE           :: 0x3022
EGL_ALPHA_SIZE          :: 0x3021
EGL_DEPTH_SIZE          :: 0x3025
EGL_RENDERABLE_TYPE     :: 0x3040
EGL_SURFACE_TYPE        :: 0x3033
EGL_WINDOW_BIT          :: 0x0004
EGL_OPENGL_ES2_BIT      :: 0x0004
EGL_CONTEXT_CLIENT_VERSION :: 0x3098
EGL_WIDTH               :: 0x3057
EGL_HEIGHT              :: 0x3056

@(default_calling_convention = "c")
foreign libegl {
	eglGetDisplay :: proc(display_id: rawptr) -> EGLDisplay ---
	eglInitialize :: proc(dpy: EGLDisplay, major, minor: ^i32) -> u32 ---
	eglChooseConfig :: proc(dpy: EGLDisplay, attrib_list: [^]i32, configs: ^EGLConfig, config_size: i32, num_config: ^i32) -> u32 ---
	eglCreateWindowSurface :: proc(dpy: EGLDisplay, config: EGLConfig, win: rawptr, attrib_list: [^]i32) -> EGLSurface ---
	eglCreateContext :: proc(dpy: EGLDisplay, config: EGLConfig, share: EGLContext, attrib_list: [^]i32) -> EGLContext ---
	eglMakeCurrent :: proc(dpy: EGLDisplay, draw, read: EGLSurface, ctx: EGLContext) -> u32 ---
	eglSwapBuffers :: proc(dpy: EGLDisplay, surface: EGLSurface) -> u32 ---
	eglQuerySurface :: proc(dpy: EGLDisplay, surface: EGLSurface, attribute: i32, value: ^i32) -> u32 ---
	eglDestroySurface :: proc(dpy: EGLDisplay, surface: EGLSurface) -> u32 ---
	eglDestroyContext :: proc(dpy: EGLDisplay, ctx: EGLContext) -> u32 ---
	eglTerminate :: proc(dpy: EGLDisplay) -> u32 ---
	eglSwapInterval :: proc(dpy: EGLDisplay, interval: i32) -> u32 ---
}

GL_COLOR_BUFFER_BIT   :: 0x4000
GL_BLEND              :: 0x0BE2
GL_SCISSOR_TEST       :: 0x0C11
GL_SRC_ALPHA          :: 0x0302
GL_ONE_MINUS_SRC_ALPHA :: 0x0303
GL_ONE                :: 1
GL_TRIANGLES          :: 0x0004
GL_FLOAT              :: 0x1406
GL_UNSIGNED_BYTE      :: 0x1401
GL_ARRAY_BUFFER       :: 0x8892
GL_STREAM_DRAW        :: 0x88E0
GL_TEXTURE_2D         :: 0x0DE1
GL_TEXTURE0           :: 0x84C0
GL_ALPHA              :: 0x1906
GL_TEXTURE_MIN_FILTER :: 0x2801
GL_TEXTURE_MAG_FILTER :: 0x2800
GL_TEXTURE_WRAP_S     :: 0x2802
GL_TEXTURE_WRAP_T     :: 0x2803
GL_LINEAR             :: 0x2601
GL_NEAREST            :: 0x2600
GL_CLAMP_TO_EDGE      :: 0x812F
GL_UNPACK_ALIGNMENT   :: 0x0CF5
GL_VERTEX_SHADER      :: 0x8B31
GL_FRAGMENT_SHADER    :: 0x8B30
GL_COMPILE_STATUS     :: 0x8B81
GL_LINK_STATUS        :: 0x8B82

@(default_calling_convention = "c")
foreign libgles {
	glViewport :: proc(x, y, w, h: i32) ---
	glClearColor :: proc(r, g, b, a: f32) ---
	glClear :: proc(mask: u32) ---
	glEnable :: proc(cap: u32) ---
	glDisable :: proc(cap: u32) ---
	glBlendFunc :: proc(s, d: u32) ---
	glScissor :: proc(x, y, w, h: i32) ---
	glCreateShader :: proc(type: u32) -> u32 ---
	glShaderSource :: proc(shader: u32, count: i32, str: [^]cstring, length: [^]i32) ---
	glCompileShader :: proc(shader: u32) ---
	glGetShaderiv :: proc(shader: u32, pname: u32, params: ^i32) ---
	glGetShaderInfoLog :: proc(shader: u32, bufsize: i32, length: ^i32, log: [^]u8) ---
	glGetProgramInfoLog :: proc(program: u32, bufsize: i32, length: ^i32, log: [^]u8) ---
	glCreateProgram :: proc() -> u32 ---
	glAttachShader :: proc(program, shader: u32) ---
	glBindAttribLocation :: proc(program: u32, index: u32, name: cstring) ---
	glLinkProgram :: proc(program: u32) ---
	glGetProgramiv :: proc(program: u32, pname: u32, params: ^i32) ---
	glUseProgram :: proc(program: u32) ---
	glGetUniformLocation :: proc(program: u32, name: cstring) -> i32 ---
	glUniform2f :: proc(loc: i32, x, y: f32) ---
	glUniform1i :: proc(loc: i32, x: i32) ---
	glGenBuffers :: proc(n: i32, buffers: ^u32) ---
	glBindBuffer :: proc(target, buffer: u32) ---
	glBufferData :: proc(target: u32, size: int, data: rawptr, usage: u32) ---
	glVertexAttribPointer :: proc(index: u32, size: i32, type: u32, normalized: u8, stride: i32, ptr: uintptr) ---
	glEnableVertexAttribArray :: proc(index: u32) ---
	glDrawArrays :: proc(mode: u32, first, count: i32) ---
	glGenTextures :: proc(n: i32, textures: ^u32) ---
	glBindTexture :: proc(target, texture: u32) ---
	glActiveTexture :: proc(texture: u32) ---
	glTexImage2D :: proc(target: u32, level, internalformat, w, h, border: i32, format, type: u32, pixels: rawptr) ---
	glTexSubImage2D :: proc(target: u32, level, x, y, w, h: i32, format, type: u32, pixels: rawptr) ---
	glTexParameteri :: proc(target, pname: u32, param: i32) ---
	glPixelStorei :: proc(pname: u32, param: i32) ---
}

// ---------------------------------------------------------------------------
// EGL surface/context
// ---------------------------------------------------------------------------

Gfx :: struct {
	display: EGLDisplay,
	surface: EGLSurface,
	ctx:     EGLContext,
	config:  EGLConfig,
	width:   i32,
	height:  i32,
	ok:      bool,
}

gfx_init :: proc(g: ^Gfx, window: rawptr) -> bool {
	g.display = eglGetDisplay(nil)
	if eglInitialize(g.display, nil, nil) == 0 do return false
	attribs := [?]i32 {
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
		EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
		EGL_NONE,
	}
	n: i32
	if eglChooseConfig(g.display, &attribs[0], &g.config, 1, &n) == 0 || n == 0 do return false
	g.surface = eglCreateWindowSurface(g.display, g.config, window, nil)
	if g.surface == nil do return false
	ctx_attribs := [?]i32{EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE}
	g.ctx = eglCreateContext(g.display, g.config, nil, &ctx_attribs[0])
	if g.ctx == nil do return false
	if eglMakeCurrent(g.display, g.surface, g.surface, g.ctx) == 0 do return false
	eglSwapInterval(g.display, 1)
	gfx_query_size(g)
	g.ok = true
	return true
}

gfx_query_size :: proc(g: ^Gfx) {
	eglQuerySurface(g.display, g.surface, EGL_WIDTH, &g.width)
	eglQuerySurface(g.display, g.surface, EGL_HEIGHT, &g.height)
}

gfx_destroy :: proc(g: ^Gfx) {
	if g.display != nil {
		eglMakeCurrent(g.display, nil, nil, nil)
		if g.ctx != nil do eglDestroyContext(g.display, g.ctx)
		if g.surface != nil do eglDestroySurface(g.display, g.surface)
		eglTerminate(g.display)
	}
	g^ = {}
}

// ---------------------------------------------------------------------------
// Batched quad renderer: one shader (texture alpha * vertex color), one atlas.
// ---------------------------------------------------------------------------

Vertex :: struct {
	x, y: f32,
	u, v: f32,
	col:  [4]u8,
}

Color :: [4]u8

Rect :: struct {
	x, y, w, h: f32,
}

rect_contains :: proc(r: Rect, x, y: f32) -> bool {
	return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

rect_intersect :: proc(a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)
	return {x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
}

Renderer :: struct {
	program:  u32,
	vbo:      u32,
	u_screen: i32,
	verts:    [dynamic]Vertex,
	clip:     Rect,
	clip_stack: [dynamic]Rect,
	screen_w, screen_h: f32,
}

VS :: `
attribute vec2 a_pos;
attribute vec2 a_uv;
attribute vec4 a_col;
uniform vec2 u_screen;
varying vec2 v_uv;
varying vec4 v_col;
void main() {
	v_uv = a_uv;
	v_col = a_col;
	gl_Position = vec4(a_pos.x / u_screen.x * 2.0 - 1.0, 1.0 - a_pos.y / u_screen.y * 2.0, 0.0, 1.0);
}
`
FS :: `
precision mediump float;
uniform sampler2D u_tex;
varying vec2 v_uv;
varying vec4 v_col;
void main() {
	float a = texture2D(u_tex, v_uv).a;
	gl_FragColor = vec4(v_col.rgb, v_col.a * a);
}
`

@(private = "file")
compile :: proc(kind: u32, src: string) -> u32 {
	s := glCreateShader(kind)
	cs := cstring(raw_data(src)) // source literals are NUL-terminated by the compiler? -- not guaranteed; copy
	buf := make([]u8, len(src) + 1, context.temp_allocator)
	copy(buf, src)
	cs = cstring(raw_data(buf))
	glShaderSource(s, 1, &cs, nil)
	glCompileShader(s)
	ok: i32
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok)
	if ok == 0 {
		logbuf: [1024]u8
		n: i32
		glGetShaderInfoLog(s, 1024, &n, &logbuf[0])
		log_info(string(logbuf[:n]))
	}
	return s
}

renderer_init :: proc(r: ^Renderer) {
	r.program = glCreateProgram()
	glAttachShader(r.program, compile(GL_VERTEX_SHADER, VS))
	glAttachShader(r.program, compile(GL_FRAGMENT_SHADER, FS))
	glBindAttribLocation(r.program, 0, "a_pos")
	glBindAttribLocation(r.program, 1, "a_uv")
	glBindAttribLocation(r.program, 2, "a_col")
	glLinkProgram(r.program)
	ok: i32
	glGetProgramiv(r.program, GL_LINK_STATUS, &ok)
	if ok == 0 {
		logbuf: [1024]u8
		n: i32
		glGetProgramInfoLog(r.program, 1024, &n, &logbuf[0])
		log_info(string(logbuf[:n]))
	}
	r.u_screen = glGetUniformLocation(r.program, "u_screen")
	glGenBuffers(1, &r.vbo)
	if r.verts == nil do r.verts = make([dynamic]Vertex, 0, 6 * 4096)
}

renderer_begin :: proc(r: ^Renderer, w, h: f32, bg: Color) {
	r.screen_w, r.screen_h = w, h
	glViewport(0, 0, i32(w), i32(h))
	glClearColor(f32(bg.r) / 255, f32(bg.g) / 255, f32(bg.b) / 255, 1)
	glDisable(GL_SCISSOR_TEST)
	glClear(GL_COLOR_BUFFER_BIT)
	glEnable(GL_BLEND)
	glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
	glEnable(GL_SCISSOR_TEST)
	glUseProgram(r.program)
	glUniform2f(r.u_screen, w, h)
	glUniform1i(glGetUniformLocation(r.program, "u_tex"), 0)
	glActiveTexture(GL_TEXTURE0)
	glBindTexture(GL_TEXTURE_2D, atlas.tex)
	clear(&r.clip_stack)
	r.clip = {0, 0, w, h}
	apply_scissor(r)
}

@(private = "file")
apply_scissor :: proc(r: ^Renderer) {
	c := r.clip
	glScissor(i32(c.x), i32(r.screen_h - (c.y + c.h)), i32(max(c.w, 0)), i32(max(c.h, 0)))
}

renderer_flush :: proc(r: ^Renderer) {
	if len(r.verts) == 0 do return
	atlas_upload()
	glBindBuffer(GL_ARRAY_BUFFER, r.vbo)
	glBufferData(GL_ARRAY_BUFFER, len(r.verts) * size_of(Vertex), raw_data(r.verts), GL_STREAM_DRAW)
	glEnableVertexAttribArray(0)
	glEnableVertexAttribArray(1)
	glEnableVertexAttribArray(2)
	glVertexAttribPointer(0, 2, GL_FLOAT, 0, size_of(Vertex), offset_of(Vertex, x))
	glVertexAttribPointer(1, 2, GL_FLOAT, 0, size_of(Vertex), offset_of(Vertex, u))
	glVertexAttribPointer(2, 4, GL_UNSIGNED_BYTE, 1, size_of(Vertex), offset_of(Vertex, col))
	glDrawArrays(GL_TRIANGLES, 0, i32(len(r.verts)))
	clear(&r.verts)
}

push_clip :: proc(r: ^Renderer, rect: Rect) {
	renderer_flush(r)
	append(&r.clip_stack, r.clip)
	r.clip = rect_intersect(r.clip, rect)
	apply_scissor(r)
}

pop_clip :: proc(r: ^Renderer) {
	renderer_flush(r)
	r.clip = pop(&r.clip_stack)
	apply_scissor(r)
}

quad :: proc(r: ^Renderer, x0, y0, x1, y1, u0, v0, u1, v1: f32, col: Color) {
	// cheap CPU-side culling against current clip
	c := r.clip
	if x1 < c.x || y1 < c.y || x0 > c.x + c.w || y0 > c.y + c.h do return
	append(&r.verts,
		Vertex{x0, y0, u0, v0, col}, Vertex{x1, y0, u1, v0, col}, Vertex{x1, y1, u1, v1, col},
		Vertex{x0, y0, u0, v0, col}, Vertex{x1, y1, u1, v1, col}, Vertex{x0, y1, u0, v1, col},
	)
}

draw_rect :: proc(r: ^Renderer, rect: Rect, col: Color) {
	u, v := atlas.white_u, atlas.white_v
	quad(r, rect.x, rect.y, rect.x + rect.w, rect.y + rect.h, u, v, u, v, col)
}

// Rounded rectangle via 9-slice of a pre-rasterized circle in the atlas.
draw_rrect :: proc(r: ^Renderer, rect: Rect, radius: f32, col: Color) {
	rad := min(radius, rect.w / 2, rect.h / 2)
	if rad < 1 {
		draw_rect(r, rect, col)
		return
	}
	x0, y0 := rect.x, rect.y
	x1, y1 := rect.x + rect.w, rect.y + rect.h
	cu0, cv0, cu1, cv1 := atlas.circle_uv[0], atlas.circle_uv[1], atlas.circle_uv[2], atlas.circle_uv[3]
	cum := (cu0 + cu1) / 2
	cvm := (cv0 + cv1) / 2
	// corners
	quad(r, x0, y0, x0 + rad, y0 + rad, cu0, cv0, cum, cvm, col)
	quad(r, x1 - rad, y0, x1, y0 + rad, cum, cv0, cu1, cvm, col)
	quad(r, x0, y1 - rad, x0 + rad, y1, cu0, cvm, cum, cv1, col)
	quad(r, x1 - rad, y1 - rad, x1, y1, cum, cvm, cu1, cv1, col)
	// edges + center
	draw_rect(r, {x0 + rad, y0, rect.w - 2 * rad, rad}, col)
	draw_rect(r, {x0 + rad, y1 - rad, rect.w - 2 * rad, rad}, col)
	draw_rect(r, {x0, y0 + rad, rect.w, rect.h - 2 * rad}, col)
}

_ :: c

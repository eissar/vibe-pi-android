package main

// Pure-Odin TrueType loader + anti-aliased rasterizer + glyph atlas.
// Reads the device's system fonts (/system/fonts/*.ttf, glyf outlines).

import "core:math"

Font :: struct {
	data:         []u8,
	ok:           bool,
	units_per_em: f32,
	ascent:       f32,
	descent:      f32,
	line_gap:     f32,
	num_glyphs:   int,
	num_hmetrics: int,
	loca_long:    bool,
	cmap_off:     int, // offset of chosen cmap subtable
	cmap_format:  int,
	glyf, loca, hmtx: int,
}

@(private = "file")
be16 :: #force_inline proc(d: []u8, o: int) -> u16 {
	if o + 2 > len(d) do return 0
	return u16(d[o]) << 8 | u16(d[o + 1])
}
@(private = "file")
bei16 :: #force_inline proc(d: []u8, o: int) -> i16 {return i16(be16(d, o))}
@(private = "file")
be32 :: #force_inline proc(d: []u8, o: int) -> u32 {
	if o + 4 > len(d) do return 0
	return u32(d[o]) << 24 | u32(d[o + 1]) << 16 | u32(d[o + 2]) << 8 | u32(d[o + 3])
}

font_load :: proc(f: ^Font, data: []u8) -> bool {
	f.data = data
	if len(data) < 12 do return false
	num_tables := int(be16(data, 4))
	tables: map[string]int
	defer delete(tables)
	for i in 0 ..< num_tables {
		rec := 12 + i * 16
		if rec + 16 > len(data) do return false
		tag := string(data[rec:rec + 4])
		tables[tag] = int(be32(data, rec + 8))
	}
	head, ok1 := tables["head"]
	hhea, ok2 := tables["hhea"]
	maxp, ok3 := tables["maxp"]
	cmap, ok4 := tables["cmap"]
	f.glyf = tables["glyf"] or_else 0
	f.loca = tables["loca"] or_else 0
	f.hmtx = tables["hmtx"] or_else 0
	if !(ok1 && ok2 && ok3 && ok4) || f.glyf == 0 || f.loca == 0 || f.hmtx == 0 do return false

	f.units_per_em = f32(be16(data, head + 18))
	f.loca_long = bei16(data, head + 50) != 0
	f.ascent = f32(bei16(data, hhea + 4))
	f.descent = f32(bei16(data, hhea + 6))
	f.line_gap = f32(bei16(data, hhea + 8))
	f.num_hmetrics = int(be16(data, hhea + 34))
	f.num_glyphs = int(be16(data, maxp + 4))

	// Prefer full-Unicode (3,10 format 12), then BMP (3,1 format 4), then any unicode platform.
	n := int(be16(data, cmap + 2))
	best_score := -1
	for i in 0 ..< n {
		rec := cmap + 4 + i * 8
		pid := be16(data, rec)
		eid := be16(data, rec + 2)
		off := cmap + int(be32(data, rec + 4))
		format := int(be16(data, off))
		score := -1
		if format == 12 && (pid == 3 && eid == 10 || pid == 0) do score = 3
		else if format == 4 && (pid == 3 && eid == 1 || pid == 0) do score = 2
		if score > best_score {
			best_score = score
			f.cmap_off = off
			f.cmap_format = format
		}
	}
	if best_score < 0 do return false
	f.ok = true
	return true
}

font_glyph_index :: proc(f: ^Font, r: rune) -> int {
	d := f.data
	o := f.cmap_off
	cp := u32(r)
	switch f.cmap_format {
	case 4:
		if cp > 0xFFFF do return 0
		segx2 := int(be16(d, o + 6))
		ends := o + 14
		starts := ends + segx2 + 2
		deltas := starts + segx2
		range_offs := deltas + segx2
		// binary search over segments
		lo, hi := 0, segx2 / 2
		for lo < hi {
			mid := (lo + hi) / 2
			if u32(be16(d, ends + mid * 2)) < cp do lo = mid + 1
			else do hi = mid
		}
		seg := lo
		if seg >= segx2 / 2 do return 0
		start := u32(be16(d, starts + seg * 2))
		if cp < start do return 0
		delta := be16(d, deltas + seg * 2)
		ro := int(be16(d, range_offs + seg * 2))
		if ro == 0 do return int(u16(cp) + delta)
		gaddr := range_offs + seg * 2 + ro + int(cp - start) * 2
		g := be16(d, gaddr)
		if g == 0 do return 0
		return int(g + delta)
	case 12:
		ngroups := int(be32(d, o + 12))
		lo, hi := 0, ngroups
		for lo < hi {
			mid := (lo + hi) / 2
			g := o + 16 + mid * 12
			sc := be32(d, g)
			ec := be32(d, g + 4)
			if cp < sc do hi = mid
			else if cp > ec do lo = mid + 1
			else do return int(be32(d, g + 8) + (cp - sc))
		}
	}
	return 0
}

font_advance :: proc(f: ^Font, glyph: int) -> f32 {
	idx := min(glyph, f.num_hmetrics - 1)
	return f32(be16(f.data, f.hmtx + idx * 4))
}

@(private = "file")
glyph_offset :: proc(f: ^Font, glyph: int) -> (int, int) {
	if glyph >= f.num_glyphs do return 0, 0
	a, b: int
	if f.loca_long {
		a = int(be32(f.data, f.loca + glyph * 4))
		b = int(be32(f.data, f.loca + glyph * 4 + 4))
	} else {
		a = int(be16(f.data, f.loca + glyph * 2)) * 2
		b = int(be16(f.data, f.loca + glyph * 2 + 2)) * 2
	}
	return f.glyf + a, b - a
}

Pt :: [2]f32

// Outline as flattened line segments (pairs of points) in font units.
@(private = "file")
Outline :: struct {
	lines: [dynamic][2]Pt,
}

@(private = "file")
Xform :: struct {
	a, b, c, d, e, f: f32, // x' = a*x + c*y + e ; y' = b*x + d*y + f
}

@(private = "file")
add_quad :: proc(o: ^Outline, p0, p1, p2: Pt, scale: f32) {
	dd := (p0 - 2 * p1 + p2) * scale
	devsq := dd.x * dd.x + dd.y * dd.y
	if devsq < 0.333 {
		append(&o.lines, [2]Pt{p0, p2})
		return
	}
	n := 1 + int(math.floor(math.sqrt(math.sqrt(3 * devsq))))
	prev := p0
	for i in 1 ..= n {
		t := f32(i) / f32(n)
		mt := 1 - t
		p := mt * mt * p0 + 2 * mt * t * p1 + t * t * p2
		append(&o.lines, [2]Pt{prev, p})
		prev = p
	}
}

@(private = "file")
load_outline :: proc(f: ^Font, glyph: int, xf: Xform, o: ^Outline, scale: f32, depth: int) {
	if depth > 8 do return
	off, length := glyph_offset(f, glyph)
	if length <= 0 do return
	d := f.data
	ncont := int(bei16(d, off))
	tp :: proc(xf: Xform, x, y: f32) -> Pt {
		return {xf.a * x + xf.c * y + xf.e, xf.b * x + xf.d * y + xf.f}
	}
	if ncont >= 0 {
		end_pts := off + 10
		npts := ncont > 0 ? int(be16(d, end_pts + (ncont - 1) * 2)) + 1 : 0
		if npts == 0 do return
		ins_len := int(be16(d, end_pts + ncont * 2))
		p := end_pts + ncont * 2 + 2 + ins_len
		flags := make([]u8, npts, context.temp_allocator)
		xs := make([]f32, npts, context.temp_allocator)
		ys := make([]f32, npts, context.temp_allocator)
		i := 0
		for i < npts {
			if p >= len(d) do return
			fl := d[p]; p += 1
			flags[i] = fl; i += 1
			if fl & 8 != 0 {
				rep := int(d[p]); p += 1
				for _ in 0 ..< rep {
					if i >= npts do break
					flags[i] = fl; i += 1
				}
			}
		}
		v: i32 = 0
		for k in 0 ..< npts {
			fl := flags[k]
			if fl & 2 != 0 {
				dx := i32(d[p]); p += 1
				v += (fl & 16 != 0) ? dx : -dx
			} else if fl & 16 == 0 {
				v += i32(bei16(d, p)); p += 2
			}
			xs[k] = f32(v)
		}
		v = 0
		for k in 0 ..< npts {
			fl := flags[k]
			if fl & 4 != 0 {
				dy := i32(d[p]); p += 1
				v += (fl & 32 != 0) ? dy : -dy
			} else if fl & 32 == 0 {
				v += i32(bei16(d, p)); p += 2
			}
			ys[k] = f32(v)
		}
		start := 0
		for ci in 0 ..< ncont {
			end := int(be16(d, end_pts + ci * 2))
			if end < start || end >= npts do break
			cnt := end - start + 1
			pt :: proc(xs, ys: []f32, start, cnt, k: int) -> Pt {
				j := start + (k % cnt + cnt) % cnt
				return {xs[j], ys[j]}
			}
			on :: proc(flags: []u8, start, cnt, k: int) -> bool {
				return flags[start + (k % cnt + cnt) % cnt] & 1 != 0
			}
			// find a starting on-curve point (or synthesize midpoint)
			first: Pt
			k0 := -1
			for k in 0 ..< cnt {
				if on(flags, start, cnt, k) {k0 = k; break}
			}
			if k0 < 0 {
				first = (pt(xs, ys, start, cnt, 0) + pt(xs, ys, start, cnt, 1)) / 2
				k0 = 0 // we treat point 0 as next control
				cur := first
				k := 1
				for step in 0 ..< cnt {
					_ = step
					ctrl := pt(xs, ys, start, cnt, k)
					nxt := (ctrl + pt(xs, ys, start, cnt, k + 1)) / 2
					add_quad(o, tp(xf, cur.x, cur.y), tp(xf, ctrl.x, ctrl.y), tp(xf, nxt.x, nxt.y), scale)
					cur = nxt
					k += 1
				}
			} else {
				first = pt(xs, ys, start, cnt, k0)
				cur := first
				k := k0 + 1
				remaining := cnt
				for remaining > 0 {
					p1 := pt(xs, ys, start, cnt, k)
					if on(flags, start, cnt, k) {
						append(&o.lines, [2]Pt{tp(xf, cur.x, cur.y), tp(xf, p1.x, p1.y)})
						cur = p1
						k += 1
						remaining -= 1
					} else {
						p2 := pt(xs, ys, start, cnt, k + 1)
						end_pt: Pt
						if on(flags, start, cnt, k + 1) {
							end_pt = p2
							k += 2
							remaining -= 2
						} else {
							end_pt = (p1 + p2) / 2
							k += 1
							remaining -= 1
						}
						add_quad(o, tp(xf, cur.x, cur.y), tp(xf, p1.x, p1.y), tp(xf, end_pt.x, end_pt.y), scale)
						cur = end_pt
					}
				}
				if cur != first do append(&o.lines, [2]Pt{tp(xf, cur.x, cur.y), tp(xf, first.x, first.y)})
			}
			start = end + 1
		}
	} else {
		// composite glyph
		p := off + 10
		for {
			fl := be16(d, p)
			gi := int(be16(d, p + 2))
			p += 4
			dx, dy: f32
			if fl & 1 != 0 {
				dx = f32(bei16(d, p)); dy = f32(bei16(d, p + 2)); p += 4
			} else {
				dx = f32(i8(d[p])); dy = f32(i8(d[p + 1])); p += 2
			}
			m := Xform{1, 0, 0, 1, dx, dy}
			if fl & 8 != 0 {
				s := f32(bei16(d, p)) / 16384; p += 2
				m.a = s; m.d = s
			} else if fl & 0x40 != 0 {
				m.a = f32(bei16(d, p)) / 16384; m.d = f32(bei16(d, p + 2)) / 16384; p += 4
			} else if fl & 0x80 != 0 {
				m.a = f32(bei16(d, p)) / 16384; m.b = f32(bei16(d, p + 2)) / 16384
				m.c = f32(bei16(d, p + 4)) / 16384; m.d = f32(bei16(d, p + 6)) / 16384
				p += 8
			}
			// combine: child coords -> m -> xf
			comb := Xform {
				a = xf.a * m.a + xf.c * m.b,
				b = xf.b * m.a + xf.d * m.b,
				c = xf.a * m.c + xf.c * m.d,
				d = xf.b * m.c + xf.d * m.d,
				e = xf.a * m.e + xf.c * m.f + xf.e,
				f = xf.b * m.e + xf.d * m.f + xf.f,
			}
			load_outline(f, gi, comb, o, scale, depth + 1)
			if fl & 0x20 == 0 do break
		}
	}
}

Raster :: struct {
	w, h:   int,
	pixels: []u8,
	xoff:   f32, // pixel offset of bitmap's left edge from pen x
	yoff:   f32, // pixel offset of bitmap's top edge from baseline (negative = above)
}

// Exact-area coverage accumulation rasterizer (same idea as font-rs).
@(private = "file")
draw_line :: proc(acc: []f32, w, h: int, p0_, p1_: Pt) {
	p0, p1 := p0_, p1_
	if abs(p0.y - p1.y) <= 1e-6 do return
	dir: f32 = 1
	if p0.y > p1.y {
		dir = -1
		p0, p1 = p1, p0
	}
	dxdy := (p1.x - p0.x) / (p1.y - p0.y)
	x := p0.x
	if p0.y < 0 do x -= p0.y * dxdy
	y_start := max(0, int(p0.y))
	y_end := min(h, int(math.ceil(p1.y)))
	for y in y_start ..< y_end {
		ls := y * w
		dy := min(f32(y + 1), p1.y) - max(f32(y), p0.y)
		xnext := x + dxdy * dy
		dd := dy * dir
		x0, x1 := x, xnext
		if x0 > x1 do x0, x1 = x1, x0
		x0f := math.floor(x0)
		x0i := int(x0f)
		x1c := math.ceil(x1)
		x1i := int(x1c)
		if x1i <= x0i + 1 {
			xmf := 0.5 * (x + xnext) - x0f
			i := ls + x0i
			if i >= 0 && i + 1 < len(acc) {
				acc[i] += dd - dd * xmf
				acc[i + 1] += dd * xmf
			}
		} else {
			s := 1 / (x1 - x0)
			x0frac := x0 - x0f
			a0 := 0.5 * s * (1 - x0frac) * (1 - x0frac)
			x1frac := x1 - x1c + 1
			am := 0.5 * s * x1frac * x1frac
			i0 := ls + x0i
			if i0 < 0 || ls + x1i >= len(acc) {
				x = xnext
				continue
			}
			acc[i0] += dd * a0
			if x1i == x0i + 2 {
				acc[i0 + 1] += dd * (1 - a0 - am)
			} else {
				a1 := s * (1.5 - x0frac)
				acc[i0 + 1] += dd * (a1 - a0)
				for xi in x0i + 2 ..< x1i - 1 do acc[ls + xi] += dd * s
				a2 := a1 + f32(x1i - x0i - 3) * s
				acc[ls + x1i - 1] += dd * (1 - a2 - am)
			}
			acc[ls + x1i] += dd * am
		}
		x = xnext
	}
}

font_rasterize :: proc(f: ^Font, glyph: int, px_size: f32, allocator := context.temp_allocator) -> Raster {
	scale := px_size / f.units_per_em
	o: Outline
	o.lines = make([dynamic][2]Pt, 0, 256, context.temp_allocator)
	load_outline(f, glyph, Xform{1, 0, 0, 1, 0, 0}, &o, scale, 0)
	if len(o.lines) == 0 do return {}
	minx, miny: f32 = 1e9, 1e9
	maxx, maxy: f32 = -1e9, -1e9
	for l in o.lines {
		for p in l {
			minx = min(minx, p.x); maxx = max(maxx, p.x)
			miny = min(miny, p.y); maxy = max(maxy, p.y)
		}
	}
	// pixel space: x right, y down; flip font y
	bx0 := math.floor(minx * scale)
	by0 := math.floor(-maxy * scale)
	bx1 := math.ceil(maxx * scale)
	by1 := math.ceil(-miny * scale)
	w := int(bx1 - bx0) + 1
	h := int(by1 - by0) + 1
	if w <= 0 || h <= 0 || w > 512 || h > 512 do return {}
	acc := make([]f32, w * h + 4, context.temp_allocator)
	for l in o.lines {
		p0 := Pt{l[0].x * scale - bx0, -l[0].y * scale - by0}
		p1 := Pt{l[1].x * scale - bx0, -l[1].y * scale - by0}
		draw_line(acc, w, h, p0, p1)
	}
	px := make([]u8, w * h, allocator)
	a: f32 = 0
	for i in 0 ..< w * h {
		a += acc[i]
		v := min(abs(a), 1)
		// slight gamma to make thin strokes read better on phones
		px[i] = u8(math.pow(v, 0.85) * 255 + 0.5)
	}
	return {w = w, h = h, pixels = px, xoff = bx0, yoff = by0}
}

// ---------------------------------------------------------------------------
// Glyph atlas (single GL_ALPHA texture, shelf packing)
// ---------------------------------------------------------------------------

ATLAS_SIZE :: 1024

Glyph :: struct {
	u0, v0, u1, v1: f32,
	w, h:           f32,
	xoff, yoff:     f32,
	advance:        f32,
	valid:          bool,
}

GlyphKey :: struct {
	r:    rune,
	size: u16,
	font: u8,
}

Atlas :: struct {
	tex:         u32,
	pixels:      []u8,
	dirty:       bool,
	shelf_x, shelf_y, shelf_h: int,
	glyphs:      map[GlyphKey]Glyph,
	white_u, white_v: f32,
	circle_uv:   [4]f32,
	generation:  int,
}

atlas: Atlas

FONT_SANS :: 0
FONT_MONO :: 1
FONT_BOLD :: 2
fonts: [3]Font

atlas_init_cpu :: proc() {
	if atlas.pixels == nil do atlas.pixels = make([]u8, ATLAS_SIZE * ATLAS_SIZE)
	atlas_reset()
}

atlas_reset :: proc() {
	for &p in atlas.pixels do p = 0
	clear(&atlas.glyphs)
	atlas.shelf_x, atlas.shelf_y, atlas.shelf_h = 0, 0, 0
	atlas.generation += 1
	// white 4x4 block for solid fills
	for y in 0 ..< 4 do for x in 0 ..< 4 do atlas.pixels[y * ATLAS_SIZE + x] = 255
	atlas.white_u = 2.0 / ATLAS_SIZE
	atlas.white_v = 2.0 / ATLAS_SIZE
	atlas.shelf_x = 6
	atlas.shelf_h = 6
	// anti-aliased circle (64px) for rounded corners
	C :: 64
	cx, cy, ok := atlas_alloc(C + 2, C + 2)
	if ok {
		for y in 0 ..< C {
			for x in 0 ..< C {
				// 4x4 supersampling
				cov := 0
				for sy in 0 ..< 4 do for sx in 0 ..< 4 {
					fx := f32(x) + (f32(sx) + 0.5) / 4 - C / 2
					fy := f32(y) + (f32(sy) + 0.5) / 4 - C / 2
					if fx * fx + fy * fy <= (C / 2) * (C / 2) do cov += 1
				}
				atlas.pixels[(cy + 1 + y) * ATLAS_SIZE + cx + 1 + x] = u8(cov * 255 / 16)
			}
		}
		atlas.circle_uv = {f32(cx + 1) / ATLAS_SIZE, f32(cy + 1) / ATLAS_SIZE, f32(cx + 1 + C) / ATLAS_SIZE, f32(cy + 1 + C) / ATLAS_SIZE}
	}
	atlas.dirty = true
}

@(private = "file")
atlas_alloc :: proc(w, h: int) -> (int, int, bool) {
	if atlas.shelf_x + w > ATLAS_SIZE {
		atlas.shelf_y += atlas.shelf_h
		atlas.shelf_x = 0
		atlas.shelf_h = 0
	}
	if atlas.shelf_y + h > ATLAS_SIZE do return 0, 0, false
	x, y := atlas.shelf_x, atlas.shelf_y
	atlas.shelf_x += w
	atlas.shelf_h = max(atlas.shelf_h, h)
	return x, y, true
}

atlas_gpu_init :: proc() {
	glGenTextures(1, &atlas.tex)
	glBindTexture(GL_TEXTURE_2D, atlas.tex)
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
	glTexImage2D(GL_TEXTURE_2D, 0, GL_ALPHA, ATLAS_SIZE, ATLAS_SIZE, 0, GL_ALPHA, GL_UNSIGNED_BYTE, raw_data(atlas.pixels))
	atlas.dirty = false
}

atlas_upload :: proc() {
	if !atlas.dirty do return
	glBindTexture(GL_TEXTURE_2D, atlas.tex)
	glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, ATLAS_SIZE, ATLAS_SIZE, GL_ALPHA, GL_UNSIGNED_BYTE, raw_data(atlas.pixels))
	atlas.dirty = false
}

// Resolve which font has the glyph (fallback to sans if mono/bold lacks it).
get_glyph :: proc(font_id: int, r: rune, size: f32) -> Glyph {
	key := GlyphKey{r, u16(size), u8(font_id)}
	if g, ok := atlas.glyphs[key]; ok do return g
	fid := font_id
	f := &fonts[fid]
	if !f.ok {fid = FONT_SANS; f = &fonts[fid]}
	gi := font_glyph_index(f, r)
	if gi == 0 && fid != FONT_SANS {
		f = &fonts[FONT_SANS]
		gi = font_glyph_index(f, r)
	}
	g: Glyph
	if !f.ok {
		atlas.glyphs[key] = g
		return g
	}
	if gi == 0 && r > 0x20 {
		// tofu: use replacement char if available, else '?'
		gi = font_glyph_index(f, 0xFFFD)
		if gi == 0 do gi = font_glyph_index(f, '?')
	}
	g.advance = font_advance(f, gi) * size / f.units_per_em
	ras := font_rasterize(f, gi, size)
	if ras.w > 0 {
		x, y, ok := atlas_alloc(ras.w + 1, ras.h + 1)
		if !ok {
			// atlas full: start over (glyphs re-rasterize lazily)
			atlas_reset()
			x, y, ok = atlas_alloc(ras.w + 1, ras.h + 1)
			if !ok do return g
		}
		for row in 0 ..< ras.h {
			copy(atlas.pixels[(y + row) * ATLAS_SIZE + x:][:ras.w], ras.pixels[row * ras.w:][:ras.w])
		}
		atlas.dirty = true
		g.u0 = f32(x) / ATLAS_SIZE
		g.v0 = f32(y) / ATLAS_SIZE
		g.u1 = f32(x + ras.w) / ATLAS_SIZE
		g.v1 = f32(y + ras.h) / ATLAS_SIZE
		g.w = f32(ras.w)
		g.h = f32(ras.h)
		g.xoff = ras.xoff
		g.yoff = ras.yoff
		g.valid = true
	}
	atlas.glyphs[key] = g
	return g
}

font_line_height :: proc(font_id: int, size: f32) -> f32 {
	f := &fonts[font_id]
	if !f.ok do f = &fonts[FONT_SANS]
	if !f.ok do return size * 1.2
	return math.ceil((f.ascent - f.descent + f.line_gap) * size / f.units_per_em)
}

font_ascent :: proc(font_id: int, size: f32) -> f32 {
	f := &fonts[font_id]
	if !f.ok do f = &fonts[FONT_SANS]
	if !f.ok do return size
	return math.round(f.ascent * size / f.units_per_em)
}

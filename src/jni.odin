package main

// Tiny JNI layer written in Odin: we call a handful of Android framework
// methods (keyboard, clipboard, key-char mapping) through the JNIEnv function
// table. Table indices come from the NDK's <jni.h>.

jobject   :: distinct rawptr
jclass    :: jobject
jstring   :: jobject
jmethodID :: distinct rawptr

jvalue :: struct #raw_union {
	z: u8,
	i: i32,
	j: i64,
	f: f32,
	d: f64,
	l: jobject,
}

JNIEnv :: ^[300]rawptr // JNIEnv* points at a pointer to the function table

@(private = "file")
JNI_FindClass :: 6
@(private = "file")
JNI_ExceptionClear :: 17
@(private = "file")
JNI_DeleteLocalRef :: 23
@(private = "file")
JNI_GetObjectClass :: 31
@(private = "file")
JNI_GetMethodID :: 33
@(private = "file")
JNI_CallObjectMethodA :: 36
@(private = "file")
JNI_CallBooleanMethodA :: 39
@(private = "file")
JNI_CallIntMethodA :: 51
@(private = "file")
JNI_CallVoidMethodA :: 63
@(private = "file")
JNI_GetStaticMethodID :: 113
@(private = "file")
JNI_CallStaticObjectMethodA :: 116
@(private = "file")
JNI_NewStringUTF :: 167
@(private = "file")
JNI_GetStringUTFChars :: 169
@(private = "file")
JNI_ReleaseStringUTFChars :: 170
@(private = "file")
JNI_ExceptionCheck :: 228

Jni :: struct {
	env: ^JNIEnv,
}

@(private = "file")
fn :: #force_inline proc(env: ^JNIEnv, idx: int, $T: typeid) -> T {
	return transmute(T)(env^[idx])
}

jni_find_class :: proc(env: ^JNIEnv, name: cstring) -> jclass {
	return fn(env, JNI_FindClass, proc "c" (^JNIEnv, cstring) -> jclass)(env, name)
}
jni_get_object_class :: proc(env: ^JNIEnv, obj: jobject) -> jclass {
	return fn(env, JNI_GetObjectClass, proc "c" (^JNIEnv, jobject) -> jclass)(env, obj)
}
jni_delete :: proc(env: ^JNIEnv, obj: jobject) {
	if obj != nil do fn(env, JNI_DeleteLocalRef, proc "c" (^JNIEnv, jobject))(env, obj)
}
jni_check :: proc(env: ^JNIEnv) -> bool {
	if fn(env, JNI_ExceptionCheck, proc "c" (^JNIEnv) -> u8)(env) != 0 {
		fn(env, JNI_ExceptionClear, proc "c" (^JNIEnv))(env)
		return false
	}
	return true
}
jni_method :: proc(env: ^JNIEnv, obj: jobject, name, sig: cstring) -> jmethodID {
	cls := jni_get_object_class(env, obj)
	defer jni_delete(env, cls)
	m := fn(env, JNI_GetMethodID, proc "c" (^JNIEnv, jclass, cstring, cstring) -> jmethodID)(env, cls, name, sig)
	jni_check(env)
	return m
}
jni_call_obj :: proc(env: ^JNIEnv, obj: jobject, name, sig: cstring, args: ..jvalue) -> jobject {
	if obj == nil do return nil
	m := jni_method(env, obj, name, sig)
	if m == nil do return nil
	r := fn(env, JNI_CallObjectMethodA, proc "c" (^JNIEnv, jobject, jmethodID, [^]jvalue) -> jobject)(env, obj, m, raw_data(args))
	if !jni_check(env) do return nil
	return r
}
jni_call_bool :: proc(env: ^JNIEnv, obj: jobject, name, sig: cstring, args: ..jvalue) -> bool {
	if obj == nil do return false
	m := jni_method(env, obj, name, sig)
	if m == nil do return false
	r := fn(env, JNI_CallBooleanMethodA, proc "c" (^JNIEnv, jobject, jmethodID, [^]jvalue) -> u8)(env, obj, m, raw_data(args))
	return jni_check(env) && r != 0
}
jni_call_int :: proc(env: ^JNIEnv, obj: jobject, name, sig: cstring, args: ..jvalue) -> i32 {
	if obj == nil do return 0
	m := jni_method(env, obj, name, sig)
	if m == nil do return 0
	r := fn(env, JNI_CallIntMethodA, proc "c" (^JNIEnv, jobject, jmethodID, [^]jvalue) -> i32)(env, obj, m, raw_data(args))
	if !jni_check(env) do return 0
	return r
}
jni_call_void :: proc(env: ^JNIEnv, obj: jobject, name, sig: cstring, args: ..jvalue) {
	if obj == nil do return
	m := jni_method(env, obj, name, sig)
	if m == nil do return
	fn(env, JNI_CallVoidMethodA, proc "c" (^JNIEnv, jobject, jmethodID, [^]jvalue))(env, obj, m, raw_data(args))
	jni_check(env)
}
jni_call_static_obj :: proc(env: ^JNIEnv, class_name, name, sig: cstring, args: ..jvalue) -> jobject {
	cls := jni_find_class(env, class_name)
	if !jni_check(env) || cls == nil do return nil
	defer jni_delete(env, cls)
	m := fn(env, JNI_GetStaticMethodID, proc "c" (^JNIEnv, jclass, cstring, cstring) -> jmethodID)(env, cls, name, sig)
	if !jni_check(env) || m == nil do return nil
	r := fn(env, JNI_CallStaticObjectMethodA, proc "c" (^JNIEnv, jclass, jmethodID, [^]jvalue) -> jobject)(env, cls, m, raw_data(args))
	if !jni_check(env) do return nil
	return r
}
// JNI wants "modified UTF-8": supplementary code points as surrogate pairs (CESU-8), NUL as C0 80.
jni_new_string :: proc(env: ^JNIEnv, s: string) -> jstring {
	cs := make([dynamic]u8, 0, len(s) + 8, context.temp_allocator)
	for r in s {
		switch {
		case r == 0:
			append(&cs, 0xC0, 0x80)
		case r >= 0x10000:
			v := u32(r) - 0x10000
			for u in ([2]u32{0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF)}) {
				append(&cs, u8(0xE0 | (u >> 12)), u8(0x80 | ((u >> 6) & 0x3F)), u8(0x80 | (u & 0x3F)))
			}
		case:
			b, n := utf8_encode(r)
			append(&cs, ..b[:n])
		}
	}
	append(&cs, 0)
	return fn(env, JNI_NewStringUTF, proc "c" (^JNIEnv, cstring) -> jstring)(env, cstring(raw_data(cs)))
}

@(private = "file")
utf8_encode :: proc(r: rune) -> ([4]u8, int) {
	b: [4]u8
	c := u32(r)
	switch {
	case c < 0x80:
		b[0] = u8(c); return b, 1
	case c < 0x800:
		b[0] = u8(0xC0 | (c >> 6)); b[1] = u8(0x80 | (c & 0x3F)); return b, 2
	case:
		b[0] = u8(0xE0 | (c >> 12)); b[1] = u8(0x80 | ((c >> 6) & 0x3F)); b[2] = u8(0x80 | (c & 0x3F)); return b, 3
	}
}
// Copies a java.lang.String into an Odin string (allocated with `allocator`).
// NOTE: JNI "modified UTF-8" differs only for NUL and supplementary chars.
jni_to_string :: proc(env: ^JNIEnv, s: jstring, allocator := context.allocator) -> string {
	if s == nil do return ""
	chars := fn(env, JNI_GetStringUTFChars, proc "c" (^JNIEnv, jstring, ^u8) -> cstring)(env, s, nil)
	if chars == nil do return ""
	out := clone_cstring(chars, allocator)
	fn(env, JNI_ReleaseStringUTFChars, proc "c" (^JNIEnv, jstring, cstring))(env, s, chars)
	return out
}

@(private = "file")
clone_cstring :: proc(cs: cstring, allocator := context.allocator) -> string {
	// Decode CESU-8 surrogate pairs back into regular 4-byte UTF-8.
	src := (cast([^]u8)cs)[:len(cs)]
	out := make([dynamic]u8, 0, len(src), allocator)
	i := 0
	for i < len(src) {
		if i + 5 < len(src) && src[i] == 0xED && src[i + 1] >= 0xA0 && src[i + 1] <= 0xAF && src[i + 3] == 0xED && src[i + 4] >= 0xB0 {
			hi := (u32(src[i]) & 0x0F) << 12 | (u32(src[i + 1]) & 0x3F) << 6 | u32(src[i + 2]) & 0x3F
			lo := (u32(src[i + 3]) & 0x0F) << 12 | (u32(src[i + 4]) & 0x3F) << 6 | u32(src[i + 5]) & 0x3F
			c := 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
			append(&out, u8(0xF0 | (c >> 18)), u8(0x80 | ((c >> 12) & 0x3F)), u8(0x80 | ((c >> 6) & 0x3F)), u8(0x80 | (c & 0x3F)))
			i += 6
		} else if i + 1 < len(src) && src[i] == 0xC0 && src[i + 1] == 0x80 {
			append(&out, 0)
			i += 2
		} else {
			append(&out, src[i])
			i += 1
		}
	}
	return string(out[:])
}

// ---------------------------------------------------------------------------
// Framework helpers (all must run on the activity's main thread, which is
// where every callback of this app executes).
// ---------------------------------------------------------------------------

// Translates a key event to a Unicode code point via android.view.KeyCharacterMap.
key_to_unicode :: proc(env: ^JNIEnv, device_id, key_code, meta: i32) -> rune {
	kcm := jni_call_static_obj(env, "android/view/KeyCharacterMap", "load", "(I)Landroid/view/KeyCharacterMap;", jvalue{i = device_id})
	if kcm == nil do return 0
	defer jni_delete(env, kcm)
	r := jni_call_int(env, kcm, "get", "(II)I", jvalue{i = key_code}, jvalue{i = meta})
	if r < 0 do return 0 // combining accent marker
	return rune(r)
}

@(private = "file")
system_service :: proc(env: ^JNIEnv, activity: jobject, name: string) -> jobject {
	s := jni_new_string(env, name)
	defer jni_delete(env, s)
	return jni_call_obj(env, activity, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;", jvalue{l = s})
}

soft_keyboard :: proc(env: ^JNIEnv, activity: jobject, show: bool) {
	imm := system_service(env, activity, "input_method")
	defer jni_delete(env, imm)
	win := jni_call_obj(env, activity, "getWindow", "()Landroid/view/Window;")
	defer jni_delete(env, win)
	decor := jni_call_obj(env, win, "getDecorView", "()Landroid/view/View;")
	defer jni_delete(env, decor)
	if show {
		jni_call_bool(env, imm, "showSoftInput", "(Landroid/view/View;I)Z", jvalue{l = decor}, jvalue{i = 0})
	} else {
		token := jni_call_obj(env, decor, "getWindowToken", "()Landroid/os/IBinder;")
		defer jni_delete(env, token)
		jni_call_bool(env, imm, "hideSoftInputFromWindow", "(Landroid/os/IBinder;I)Z", jvalue{l = token}, jvalue{i = 0})
	}
}

clipboard_get :: proc(env: ^JNIEnv, activity: jobject, allocator := context.allocator) -> string {
	cm := system_service(env, activity, "clipboard")
	defer jni_delete(env, cm)
	clip := jni_call_obj(env, cm, "getPrimaryClip", "()Landroid/content/ClipData;")
	if clip == nil do return ""
	defer jni_delete(env, clip)
	if jni_call_int(env, clip, "getItemCount", "()I") <= 0 do return ""
	item := jni_call_obj(env, clip, "getItemAt", "(I)Landroid/content/ClipData$Item;", jvalue{i = 0})
	defer jni_delete(env, item)
	cs := jni_call_obj(env, item, "coerceToText", "(Landroid/content/Context;)Ljava/lang/CharSequence;", jvalue{l = activity})
	defer jni_delete(env, cs)
	str := jni_call_obj(env, cs, "toString", "()Ljava/lang/String;")
	defer jni_delete(env, str)
	return jni_to_string(env, str, allocator)
}

clipboard_set :: proc(env: ^JNIEnv, activity: jobject, text: string) {
	cm := system_service(env, activity, "clipboard")
	defer jni_delete(env, cm)
	label := jni_new_string(env, "Pi Agent")
	defer jni_delete(env, label)
	jtext := jni_new_string(env, text)
	defer jni_delete(env, jtext)
	clip := jni_call_static_obj(env, "android/content/ClipData", "newPlainText",
		"(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Landroid/content/ClipData;", jvalue{l = label}, jvalue{l = jtext})
	defer jni_delete(env, clip)
	jni_call_void(env, cm, "setPrimaryClip", "(Landroid/content/ClipData;)V", jvalue{l = clip})
}

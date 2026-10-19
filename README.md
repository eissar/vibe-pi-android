# vibe-pi-android

Native Android client for pi-agent-webui, written entirely in **Odin**.
No Java/Kotlin, no Gradle, no WebView: a `NativeActivity` loads `libmain.so`, which draws its own UI with
OpenGL ES, rasterizes system TrueType fonts itself, and speaks the webui's WebSocket RPC (`/rpc`).

## Install via F-Droid

1. In the F-Droid app: **Settings → Repositories → +**
2. Add:
   ```
   https://raw.githubusercontent.com/eissar/vibe-pi-android/main/fdroid/repo?fingerprint=59924C4DCE9F2862EE73B44FE63C130ACB74D2076AB35FFB8615C91C981AEDF9
   ```
3. Refresh, search **Pi Agent**, install. Updates arrive through F-Droid.

Requires Android 10+ (arm64 or x86_64).

## Use

Start the server reachable from the phone (LAN / Tailscale; `ws://` only, no TLS):

```bash
PI_WEBUI_HOST=0.0.0.0 npm start   # in pi-agent-webui
```

Open the app, enter `<pc-ip>:7860` (plus a token if you set `PI_WEBUI_TOKEN`) and connect.

## Build

Needs Odin, Android SDK build-tools 34 + platform 34 and NDK r27 in `~/Android/Sdk`.

```bash
./build.sh            # -> build/pi-agent.apk
./build.sh install    # + adb install
./release.sh          # bump version, rebuild, regenerate fdroid/repo, commit, push
```

Source layout: `src/main.odin` (activity + looper), `android.odin`/`jni.odin` (NDK + JNI bindings),
`gl.odin` (EGL/GLES renderer), `font.odin`/`text.odin` (TTF rasterizer), `net.odin` (WebSocket),
`rpc.odin`/`app.odin` (protocol + state), `ui.odin`/`screens.odin`/`chat.odin` (UI).

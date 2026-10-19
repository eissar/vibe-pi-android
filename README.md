# vibe-pi-android

Native Android client for pi-agent-webui, written in **Odin** on top of **SDL3** (window, input, IME,
clipboard), **SDL3_ttf** (text) and **Clay** (declarative layout). No WebView, no Gradle, no project Java:
the activity is SDL's stock `SDLActivity`, which loads `libmain.so` and calls `SDL_main`.

The earlier dependency-free version (own GL renderer, font rasterizer, NativeActivity) lives on the
[`odin-native`](../../tree/odin-native) branch.

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

Needs Odin, cmake, Android SDK (build-tools 34/36, platform 34) + NDK r27 in `~/Android/Sdk`, and a JDK
at `~/.local/share/vibe-pi-android/jdk` (for compiling SDL's Java glue and signing the F-Droid index).

```bash
tools/deps.sh         # once: fetch + cross-compile SDL3, SDL3_ttf, Clay; build SDL's classes.dex
./build.sh            # -> build/pi-agent.apk
./build.sh install    # + adb install
./release.sh          # bump version, rebuild, regenerate fdroid/repo, commit, push
```

Source: `src/main.odin` (SDL loop + Clay renderer), `ui.odin` (input, widgets, icons, text fields),
`screens.odin` (all screens), `net.odin` (WebSocket), `rpc.odin`/`app.odin` (protocol + state),
`src/clay/` (Clay's Odin bindings).

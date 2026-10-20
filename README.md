# vibe-pi-android

Native Android client for pi-agent-webui, written in **Kotlin + Jetpack Compose**. It speaks the webui's
WebSocket RPC protocol (`/rpc`) directly; no WebView.

The earlier Odin/SDL3 version lives on `main`; the dependency-free Odin version on `odin-native`.

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

Needs JDK 17+ and the Android SDK (platform 34) in `~/Android/Sdk` (or `local.properties` / `ANDROID_HOME`).

```bash
./gradlew assembleRelease   # -> app/build/outputs/apk/release/app-release.apk
./gradlew installRelease    # + adb install
./release.sh                # bump version, rebuild, regenerate fdroid/repo, commit, push
```

Release builds are signed with `~/.config/vibe-pi-android/release.keystore` if present, else `debug.keystore`.

Source (`app/src/main/java/dev/eissar/piagent/`), written against the server's WebSocket API:
- `Rpc.kt`: WebSocket RPC client (request/response, subscribe/event)
- `AppState.kt`: connection, sessions, models, chat streaming, extension dialogs
- `Ui.kt`: Compose screens

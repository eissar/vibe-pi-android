#!/usr/bin/env bash
# Builds the Pi Agent Android app: Odin -> libmain.so (per ABI) -> signed APK.
# Native deps (SDL3, SDL3_ttf, Clay) and SDL's Java glue come from tools/deps.sh.
# No Gradle.
#
# Usage: ./build.sh [arm64|x86_64|all]   (default: all)
#        ./build.sh install               (build all + adb install)
set -euo pipefail
cd "$(dirname "$0")"

SDK="${ANDROID_HOME:-$HOME/Android/Sdk}"
NDK="${ODIN_ANDROID_NDK:-$(ls -d "$SDK"/ndk/* | sort -V | tail -1)}"
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
PLATFORM="$SDK/platforms/android-34/android.jar"
API=29  # ELF TLS (used by Odin's runtime) needs Android 10+
OUT=build
APK="$OUT/pi-agent.apk"
KEYSTORE="${KEYSTORE:-$HOME/.config/vibe-pi-android/release.keystore}"
KS_PASS_FILE="${KS_PASS_FILE:-$HOME/.config/vibe-pi-android/release.pass}"
if [[ ! -f "$KEYSTORE" ]]; then KEYSTORE=debug.keystore; KS_PASS=android; else KS_PASS="$(cat "$KS_PASS_FILE")"; fi

what="${1:-all}"
install=0
if [[ "$what" == "install" ]]; then install=1; what=all; fi

export ODIN_ANDROID_NDK="$NDK/"
DEPS=build/deps
[[ -f $DEPS/classes.dex ]] || tools/deps.sh

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"

# Odin compiles to one object file; we link it with the NDK's clang ourselves
# (Odin's built-in Android link step only kicks in when cross-compiling, so it
# would skip x86_64 on an x86_64 host).
build_abi() {
  local target="$1" abi="$2" triple="$3"
  mkdir -p "$OUT/apk/lib/$abi" "$OUT/obj"
  echo "==> odin build ($abi)"
  odin build src -target:"$target" -subtarget:android -build-mode:obj \
    -minimum-os-version:$API -o:speed -use-single-module \
    -out:"$OUT/obj/libmain-$abi.o"
  "$TOOLCHAIN/bin/clang" --target="$triple$API" -shared -o "$OUT/apk/lib/$abi/libmain.so" \
    "$OUT/obj/libmain-$abi.o" -L"$DEPS/$abi" -lclay -lSDL3 -lSDL3_ttf \
    -Wl,-init,_odin_entry_point -Wl,-fini,_odin_exit_point \
    -Wl,-z,max-page-size=16384 -Wl,--no-undefined -Wl,--gc-sections -s \
    -landroid -llog -lm -lc
  for so in "$DEPS/$abi"/*.so; do "$TOOLCHAIN/bin/llvm-strip" --strip-unneeded -o "$OUT/apk/lib/$abi/$(basename "$so")" "$so"; done
}

rm -rf "$OUT/apk"
case "$what" in
  arm64)  build_abi linux_arm64 arm64-v8a aarch64-linux-android ;;
  x86_64) build_abi linux_amd64 x86_64 x86_64-linux-android ;;
  all)    build_abi linux_arm64 arm64-v8a aarch64-linux-android
          build_abi linux_amd64 x86_64 x86_64-linux-android ;;
  *) echo "unknown target: $what"; exit 1 ;;
esac

if [[ ! -f "$KEYSTORE" ]]; then
  keytool -genkeypair -keystore "$KEYSTORE" -alias androiddebugkey -storepass android \
    -keypass android -dname "CN=Android Debug,O=Android,C=US" -keyalg RSA -keysize 2048 -validity 10000
fi

echo "==> package"
rm -f "$OUT/unsigned.apk" "$OUT/aligned.apk" "$APK"
cp "$DEPS/classes.dex" "$OUT/apk/"
"$BT/aapt" package -f -M AndroidManifest.xml -I "$PLATFORM" -F "$OUT/unsigned.apk" "$OUT/apk"
"$BT/zipalign" -f -p 16 "$OUT/unsigned.apk" "$OUT/aligned.apk"
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" \
  --out "$APK" "$OUT/aligned.apk"
rm -f "$OUT/unsigned.apk" "$OUT/aligned.apk"
ls -la "$APK"

if [[ $install == 1 ]]; then
  "$SDK/platform-tools/adb" install -r "$APK"
fi

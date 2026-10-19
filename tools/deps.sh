#!/usr/bin/env bash
# Fetches and cross-compiles the native dependencies for every ABI:
#   SDL3 (window/input/IME/clipboard), SDL3_ttf (+vendored FreeType/HarfBuzz), Clay (layout).
# Also compiles SDL's Java glue (SDLActivity) into classes.dex — we write no Java ourselves.
# Output: build/deps/<abi>/lib*.so|a, build/deps/classes.dex
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
SDK="${ANDROID_HOME:-$HOME/Android/Sdk}"
NDK="$(ls -d "$SDK"/ndk/* | sort -V | tail -1)"
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
JDK="$HOME/.local/share/vibe-pi-android/jdk"
API=29
TP=third_party
OUT=build/deps

SDL_TAG=release-3.4.2
TTF_TAG=release-3.2.2

mkdir -p $TP $OUT
[[ -d $TP/SDL ]] || git clone --depth 1 --branch $SDL_TAG https://github.com/libsdl-org/SDL.git $TP/SDL
[[ -d $TP/SDL_ttf ]] || git clone --depth 1 --branch $TTF_TAG --recurse-submodules --shallow-submodules https://github.com/libsdl-org/SDL_ttf.git $TP/SDL_ttf
[[ -d $TP/clay ]] || git clone --depth 1 https://github.com/nicbarker/clay.git $TP/clay

TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
CMAKE_COMMON=(-G Ninja -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"
  -DANDROID_PLATFORM=android-$API -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,max-page-size=16384")
command -v ninja >/dev/null || CMAKE_COMMON[1]="Unix Makefiles"

for pair in arm64-v8a:aarch64-linux-android x86_64:x86_64-linux-android; do
  abi=${pair%%:*}; triple=${pair##*:}
  dst=$OUT/$abi; mkdir -p $dst
  if [[ ! -f $dst/libSDL3.so ]]; then
    echo "==> SDL3 ($abi)"
    cmake -S $TP/SDL -B build/cmake/sdl-$abi "${CMAKE_COMMON[@]}" -DANDROID_ABI=$abi \
      -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
      -DCMAKE_INSTALL_PREFIX="$ROOT/build/cmake/prefix-$abi" >/dev/null
    cmake --build build/cmake/sdl-$abi -j"$(nproc)" >/dev/null
    cmake --install build/cmake/sdl-$abi >/dev/null
    cp build/cmake/prefix-$abi/lib/libSDL3.so $dst/
  fi
  if [[ ! -f $dst/libSDL3_ttf.so ]]; then
    echo "==> SDL3_ttf ($abi)"
    cmake -S $TP/SDL_ttf -B build/cmake/ttf-$abi "${CMAKE_COMMON[@]}" -DANDROID_ABI=$abi \
      -DSDL3_DIR="$ROOT/build/cmake/prefix-$abi/lib/cmake/SDL3" \
      -DBUILD_SHARED_LIBS=ON -DSDLTTF_VENDORED=ON -DSDLTTF_HARFBUZZ=ON -DSDLTTF_PLUTOSVG=OFF \
      -DSDLTTF_SAMPLES=OFF -DSDLTTF_INSTALL=OFF >/dev/null
    cmake --build build/cmake/ttf-$abi -j"$(nproc)" >/dev/null
    cp build/cmake/ttf-$abi/libSDL3_ttf.so $dst/
  fi
  if [[ ! -f $dst/libclay.a ]]; then
    echo "==> clay ($abi)"
    cp $TP/clay/clay.h build/cmake/clay.c
    "$TC/bin/clang" --target=$triple$API -c -DCLAY_IMPLEMENTATION -O3 -fPIC -o build/cmake/clay-$abi.o build/cmake/clay.c
    "$TC/bin/llvm-ar" rcs $dst/libclay.a build/cmake/clay-$abi.o
  fi
done

if [[ ! -f $OUT/classes.dex ]]; then
  echo "==> SDL Java glue -> classes.dex"
  rm -rf build/cmake/java && mkdir -p build/cmake/java
  "$JDK/bin/javac" -nowarn -source 8 -target 8 -Xlint:-options \
    -bootclasspath "$SDK/platforms/android-34/android.jar" -d build/cmake/java \
    $(find $TP/SDL/android-project/app/src/main/java -name '*.java')
  "$BT/d8" --release --min-api $API --lib "$SDK/platforms/android-34/android.jar" \
    --output $OUT $(find build/cmake/java -name '*.class')
fi
ls -la $OUT $OUT/*/

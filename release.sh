#!/usr/bin/env bash
# Build, bump version, regenerate the F-Droid repo (served raw from GitHub), commit and push.
# Secrets live outside the tree in ~/.config/vibe-pi-android/.
set -euo pipefail
cd "$(dirname "$0")"
D="$HOME/.local/share/vibe-pi-android/jdk"
export PATH="$D/bin:$PATH" JAVA_HOME="$D" ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"

code=$(grep -o 'versionCode="[0-9]*"' AndroidManifest.xml | grep -o '[0-9]*')
if [[ "${1:-}" != "--no-bump" ]]; then
  code=$((code + 1))
  sed -i "s/versionCode=\"[0-9]*\"/versionCode=\"$code\"/; s/versionName=\"[^\"]*\"/versionName=\"0.$code\"/" AndroidManifest.xml
fi
./build.sh
cp ~/.config/vibe-pi-android/fdroid-config.yml fdroid/config.yml
cp build/pi-agent.apk "fdroid/repo/dev.eissar.piagent_$code.apk"
(cd fdroid && fdroid update)
git add -A && git commit -m "Release v0.$code" && git push

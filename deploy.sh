#!/usr/bin/env bash
set -euo pipefail
export JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
export ANDROID_HOME="/opt/homebrew/share/android-commandlinetools"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="/opt/homebrew/opt/openjdk@21/bin:/opt/homebrew/opt/gradle@8/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/build-tools/36.1.0:$ANDROID_HOME/platform-tools:/opt/homebrew/bin:$PATH"

cd "$(dirname "$0")"
mkdir -p builds

if [[ -d "android/build/src/main/java/com/godot/game" ]]; then
  cp native_plugin/*.kt android/build/src/main/java/com/godot/game/
fi

if [[ "${1:-}" != "--skip-export" ]]; then
  echo "[1/4] Exporting standalone Wisp Quest APK via Godot 4.7.2..."
  /Applications/Godot-4.7.2.app/Contents/MacOS/Godot --headless --xr-mode off --export-debug "Meta Quest" builds/QuestCompanionStarter.apk
else
  echo "[1/4] Skipping Godot export (--skip-export)."
fi

echo "[2/4] Checking connected Quest 3 via adb..."
adb devices -l
adb install -r builds/QuestCompanionStarter.apk

echo "[3/4] Granting Camera, Microphone & Hand Tracking permissions..."
adb shell pm grant com.cayde.questcompanion android.permission.CAMERA || true
adb shell pm grant com.cayde.questcompanion horizonos.permission.HEADSET_CAMERA || true
adb shell pm grant com.cayde.questcompanion android.permission.RECORD_AUDIO || true
adb shell pm grant com.cayde.questcompanion com.oculus.permission.HAND_TRACKING || true

echo "[4/4] Launching Wisp Standalone MR Companion on Quest 3..."
adb shell am force-stop com.cayde.questcompanion || true
adb shell monkey -p com.cayde.questcompanion -c android.intent.category.LAUNCHER 1

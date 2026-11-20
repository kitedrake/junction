#!/bin/sh
# Builds build/Junction.app with the audio driver inside it (Contents/Resources/JunctionDriver.driver), plus a
# standalone build/JunctionDriver.driver. Uses Xcode's toolchain when Xcode is installed (the Command Line Tools
# don't include the macOS 26 SDK that SwiftUI's Liquid Glass needs).
#
# Signing is ad-hoc unless JUNCTION_SIGN_IDENTITY names a code-signing identity (for example an "Apple
# Development" certificate). With a stable identity macOS keeps Junction's microphone and system-audio
# permissions across rebuilds; with ad-hoc signing it asks again after each build.
set -eu
cd "$(dirname "$0")"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
version="$(cat VERSION)"
build_number="$(date +%Y%m%d%H%M)"
identity="${JUNCTION_SIGN_IDENTITY:--}"
grep -q "#define kDriverVersion \"$version\"" Driver/JunctionDriver.c \
  || { echo "kDriverVersion in Driver/JunctionDriver.c doesn't match VERSION ($version)" >&2; exit 1; }

# 1. The HAL driver: a plain C bundle for Apple silicon and Intel.
driver="build/JunctionDriver.driver"
rm -rf "$driver"
mkdir -p "$driver/Contents/MacOS"
xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=26.0 -bundle -O2 -Wall -Wextra -Werror -Wno-four-char-constants \
  -fvisibility=hidden -framework CoreAudio -framework CoreFoundation \
  Driver/JunctionDriver.c -o "$driver/Contents/MacOS/JunctionDriver"
sed -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build_number/" Driver/Info.plist > "$driver/Contents/Info.plist"
codesign --force --sign "$identity" "$driver"

# 2. The app.
xcrun swift build -c release --product Junction
bin="$(xcrun swift build -c release --show-bin-path)/Junction"
app="build/Junction.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Junction"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"; fi
ditto "$driver" "$app/Contents/Resources/JunctionDriver.driver"
cp scripts/install-driver.sh scripts/uninstall-driver.sh "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Junction</string>
  <key>CFBundleDisplayName</key><string>Junction</string>
  <key>CFBundleIdentifier</key><string>local.junction.app</string>
  <key>CFBundleExecutable</key><string>Junction</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${build_number}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Junction routes audio from your microphones, audio interfaces and its own virtual devices.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Junction captures the sound apps play so you can route it, for example to a stream without your call.</string>
  <key>NSHumanReadableCopyright</key><string>Junction by omso. GNU GPL v3 or later.</string>
</dict>
</plist>
PLIST
codesign --force --sign "$identity" "$app"
echo "Built $(pwd)/$app"

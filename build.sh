#!/bin/sh
# Builds build/Junction.app with the audio driver inside it (Contents/Resources/JunctionDriver.driver), plus a
# standalone build/JunctionDriver.driver. Uses Xcode's toolchain when Xcode is installed (the Command Line Tools
# don't include the macOS 26 SDK that SwiftUI's Liquid Glass needs).
#
# Signing is ad-hoc unless SIGN_IDENTITY (or JUNCTION_SIGN_IDENTITY) names a code-signing identity (for example an
# "Apple Development" certificate). With a stable identity macOS keeps Junction's microphone and system-audio
# permissions across rebuilds; with ad-hoc signing it asks again after each build. A "Developer ID Application"
# identity (releases) also turns on the hardened runtime with Resources/Junction.entitlements and a secure
# timestamp, as notarization requires.
#
# The app's version is VERSION; the driver's is Driver/VERSION, bumped only when the driver changes, so an app
# update doesn't ask users to reinstall the driver.
#
# A plain ./build.sh has no update feed, so it never checks for updates. Release builds also set (see "Updates and
# releases" in the README):
#   UPDATE_FEED_URL    the Sparkle update feed, e.g. https://example.com/updates/junction/appcast.xml
#   UPDATE_PUBLIC_KEY  the EdDSA public key (base64) whose private half signs the updates
set -eu
cd "$(dirname "$0")"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
version="${APP_VERSION:-$(tr -d '[:space:]' < VERSION)}"   # APP_VERSION: for update tests only
driver_version="$(tr -d '[:space:]' < Driver/VERSION)"
build_number="$(date +%Y%m%d%H%M)"
identity="${SIGN_IDENTITY:-${JUNCTION_SIGN_IDENTITY:--}}"
feed="${UPDATE_FEED_URL:-}"
key="${UPDATE_PUBLIC_KEY:-}"
if { [ -n "$feed" ] && [ -z "$key" ]; } || { [ -z "$feed" ] && [ -n "$key" ]; }; then
  echo "Set both UPDATE_FEED_URL and UPDATE_PUBLIC_KEY, or neither." >&2
  exit 1
fi
grep -q "#define kDriverVersion \"$driver_version\"" Driver/JunctionDriver.c \
  || { echo "kDriverVersion in Driver/JunctionDriver.c doesn't match Driver/VERSION ($driver_version)" >&2; exit 1; }

# sign_code PATH [ENTITLEMENTS]: ad-hoc or development signing as before; Developer ID adds the hardened runtime.
sign_code() {
  case "$identity" in
    "Developer ID"*)
      if [ -n "${2:-}" ]; then
        codesign --force --sign "$identity" --options runtime --timestamp --entitlements "$2" "$1"
      else
        codesign --force --sign "$identity" --options runtime --timestamp "$1"
      fi ;;
    *) codesign --force --sign "$identity" "$1" ;;
  esac
}

# 1. The HAL driver: a plain C bundle for Apple silicon and Intel.
driver="build/JunctionDriver.driver"
rm -rf "$driver"
mkdir -p "$driver/Contents/MacOS"
xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=26.0 -bundle -O2 -Wall -Wextra -Werror -Wno-four-char-constants \
  -fvisibility=hidden -framework CoreAudio -framework CoreFoundation \
  Driver/JunctionDriver.c -o "$driver/Contents/MacOS/JunctionDriver"
sed -e "s/__VERSION__/$driver_version/" -e "s/__BUILD__/$build_number/" Driver/Info.plist > "$driver/Contents/Info.plist"
sign_code "$driver"

# 2. The app.
xcrun swift build -c release --product Junction
bindir="$(xcrun swift build -c release --show-bin-path)"
app="build/Junction.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bindir/Junction" "$app/Contents/MacOS/Junction"
# Sparkle, for in-app updates. Junction isn't sandboxed, so Sparkle's XPC services aren't needed.
framework="$app/Contents/Frameworks/Sparkle.framework"
ditto "$bindir/Sparkle.framework" "$framework"
rm -rf "$framework/XPCServices" "$framework/Versions/B/XPCServices"
if ! otool -l "$app/Contents/MacOS/Junction" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/Junction"
fi
updates=""
if [ -n "$feed" ]; then
  updates="<key>SUFeedURL</key><string>$feed</string>
  <key>SUPublicEDKey</key><string>$key</string>"
fi
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
  <key>CFBundleVersion</key><string>${version}</string>
  $updates
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Junction routes audio from your microphones, audio interfaces and its own virtual devices.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Junction captures the sound apps play so you can route it, for example to a stream without your call.</string>
  <key>NSHumanReadableCopyright</key><string>Junction by omso. GNU GPL v3 or later.</string>
</dict>
</plist>
PLIST
# Sign from the inside out.
sign_code "$app/Contents/Resources/JunctionDriver.driver"
sign_code "$framework/Versions/B/Autoupdate"
sign_code "$framework/Versions/B/Updater.app"
sign_code "$framework"
sign_code "$app" Resources/Junction.entitlements
echo "Built $(pwd)/$app"

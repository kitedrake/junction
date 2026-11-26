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
#
# Every build carries Junction Helper (Contents/Library/LoginItems/JunctionHelper.app), which can run routing in the
# background, and its launch agent (Contents/Library/LaunchAgents/local.junction.helper.plist). Whether the app
# registers and uses it is ROUTING_HELPER: 1 routes in the helper, 0 (the default, release builds included) inside the
# app. It stays off by default until the helper has been tried on a real Mac.
#
# Every build also carries Junction Driver Installer (Contents/Library/HelperTools/JunctionDriverDaemon), a launch
# daemon that installs and removes the driver without a password once the user approves it, and its plist
# (Contents/Library/LaunchDaemons/local.junction.driverd.plist). DRIVER_DAEMON decides whether the app registers and
# uses it: 1 or 0, defaulting to 0 like ROUTING_HELPER. It only works when signed by a developer team: an ad-hoc
# signed daemon accepts no connections.
#
# Crash reports are opt-in (Settings). Release builds can also set
#   CRASH_REPORT_URL   an https:// address the app POSTs a crash report to, as plain text, after the user has read
#                      it and clicked Send Report. Without it (plain and omso Builder builds) the app offers Copy
#                      Report instead. Like the update feed, it is for release builds only (needs UPDATE_FEED_URL).
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
routing_helper="${ROUTING_HELPER:-0}"
driver_daemon="${DRIVER_DAEMON:-0}"
crash_url="${CRASH_REPORT_URL:-}"
case "$routing_helper" in
  1) uses_helper="<true/>" ;;
  0) uses_helper="<false/>" ;;
  *) echo "ROUTING_HELPER must be 1 or 0." >&2; exit 1 ;;
esac
case "$driver_daemon" in
  1) uses_daemon="<true/>" ;;
  0) uses_daemon="<false/>" ;;
  *) echo "DRIVER_DAEMON must be 1 or 0." >&2; exit 1 ;;
esac
if [ -n "$crash_url" ] && [ -z "$feed" ]; then
  echo "CRASH_REPORT_URL is for release builds: set it together with UPDATE_FEED_URL." >&2
  exit 1
fi
case "$crash_url" in
  ""|https://*) ;;
  *) echo "CRASH_REPORT_URL must be an https:// address." >&2; exit 1 ;;
esac
if { [ -n "$feed" ] && [ -z "$key" ]; } || { [ -z "$feed" ] && [ -n "$key" ]; }; then
  echo "Set both UPDATE_FEED_URL and UPDATE_PUBLIC_KEY, or neither." >&2
  exit 1
fi
# SwiftPM sandboxes its manifest builds; inside another sandbox (an automated check runner's, for example) that fails with
# "sandbox_apply: Operation not permitted", so turn SwiftPM's own sandbox off there. Such a sandbox usually has no
# network either, so use the packages SwiftPM already has cached (--skip-update) instead of fetching updates first.
spm_flags=""
if ! /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null; then spm_flags="--disable-sandbox --skip-update"; fi
grep -q "#define kDriverVersion \"$driver_version\"" Driver/JunctionDriver.c \
  || { echo "kDriverVersion in Driver/JunctionDriver.c doesn't match Driver/VERSION ($driver_version)" >&2; exit 1; }

# sign_code PATH [ENTITLEMENTS] [IDENTIFIER]: ad-hoc or development signing as before; Developer ID adds the
# hardened runtime. IDENTIFIER names a bare executable (the driver installer), which has no Info.plist to take it from.
sign_code() {
  set -- "$1" "${2:-}" "${3:-}"
  extra=""
  if [ -n "$3" ]; then extra="--identifier $3"; fi
  case "$identity" in
    "Developer ID"*)
      if [ -n "$2" ]; then
        codesign --force --sign "$identity" --options runtime --timestamp $extra --entitlements "$2" "$1"
      else
        codesign --force --sign "$identity" --options runtime --timestamp $extra "$1"
      fi ;;
    *) codesign --force --sign "$identity" $extra "$1" ;;
  esac
}

# 1. The HAL driver: a plain C bundle for Apple silicon and Intel, with the device icons it offers
#    (Driver/Icons, made by scripts/make-driver-icons.swift).
driver="build/JunctionDriver.driver"
rm -rf "$driver"
mkdir -p "$driver/Contents/MacOS" "$driver/Contents/Resources"
cp Driver/Icons/*.icns "$driver/Contents/Resources/"
xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=26.0 -bundle -O2 -Wall -Wextra -Werror -Wno-four-char-constants \
  -fvisibility=hidden -framework CoreAudio -framework CoreFoundation \
  Driver/JunctionDriver.c -o "$driver/Contents/MacOS/JunctionDriver"
sed -e "s/__VERSION__/$driver_version/" -e "s/__BUILD__/$build_number/" Driver/Info.plist > "$driver/Contents/Info.plist"
sign_code "$driver"

# 2. The app, its routing helper and its driver installer.
xcrun swift build $spm_flags -c release --product Junction
xcrun swift build $spm_flags -c release --product JunctionHelper
xcrun swift build $spm_flags -c release --product JunctionDriverDaemon
bindir="$(xcrun swift build $spm_flags -c release --show-bin-path)"
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
# Junction Helper: a UI-element app (no Dock icon). Its name is the one macOS shows in the permission prompts when
# routing runs in it.
helper="$app/Contents/Library/LoginItems/JunctionHelper.app"
mkdir -p "$helper/Contents/MacOS" "$helper/Contents/Resources" "$app/Contents/Library/LaunchAgents"
cp "$bindir/JunctionHelper" "$helper/Contents/MacOS/JunctionHelper"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$helper/Contents/Resources/AppIcon.icns"; fi
cat > "$helper/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Junction Helper</string>
  <key>CFBundleDisplayName</key><string>Junction Helper</string>
  <key>CFBundleIdentifier</key><string>local.junction.helper</string>
  <key>CFBundleExecutable</key><string>JunctionHelper</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Junction Helper routes audio in the background from your microphones, audio interfaces and Junction's virtual devices.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Junction Helper captures the sound apps play so Junction can route it in the background, for example to a stream without your call.</string>
  <key>NSHumanReadableCopyright</key><string>Junction by omso. GNU GPL v3 or later.</string>
</dict>
</plist>
PLIST
cp Resources/local.junction.helper.plist "$app/Contents/Library/LaunchAgents/local.junction.helper.plist"
# Junction Driver Installer: a bare executable launchd runs as root (BundleProgram in its plist).
mkdir -p "$app/Contents/Library/HelperTools" "$app/Contents/Library/LaunchDaemons"
cp "$bindir/JunctionDriverDaemon" "$app/Contents/Library/HelperTools/JunctionDriverDaemon"
cp Resources/local.junction.driverd.plist "$app/Contents/Library/LaunchDaemons/local.junction.driverd.plist"
crash=""
if [ -n "$crash_url" ]; then crash="<key>JunctionCrashReportURL</key><string>$crash_url</string>"; fi
cp scripts/install-driver.sh scripts/uninstall-driver.sh "$app/Contents/Resources/"
# The headphone library: the bundled copy of the open headphone EQ database, with its licences, logo and SOURCE.md.
ditto Resources/HeadphoneLibrary "$app/Contents/Resources/HeadphoneLibrary"
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
  <key>JunctionRoutingHelper</key>$uses_helper
  <key>JunctionDriverDaemon</key>$uses_daemon
  $crash
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
sign_code "$helper" Resources/Junction.entitlements
sign_code "$app/Contents/Library/HelperTools/JunctionDriverDaemon" "" local.junction.driverd
sign_code "$framework/Versions/B/Autoupdate"
sign_code "$framework/Versions/B/Updater.app"
sign_code "$framework"
sign_code "$app" Resources/Junction.entitlements
echo "Built $(pwd)/$app (routing in the helper: $([ "$routing_helper" = 1 ] && echo on || echo off); driver installer: $([ "$driver_daemon" = 1 ] && echo on || echo off); crash reports: $([ -n "$crash_url" ] && echo "sent to $crash_url" || echo copy only))"

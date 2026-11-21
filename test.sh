#!/bin/sh
# Runs the engine tests, then the driver harness: the driver is built with address and undefined-behaviour
# sanitizers and loaded into a test process with a stand-in host. Nothing is installed.
set -eu
cd "$(dirname "$0")"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun swift test "$@"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/junction-harness.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
sanitize="-fsanitize=address,undefined -fno-omit-frame-pointer -g"
mkdir -p "$tmp/JunctionDriver.driver/Contents/MacOS"
xcrun clang $sanitize -mmacosx-version-min=26.0 -bundle -O1 -Wall -Wextra -Werror -Wno-four-char-constants -fvisibility=hidden \
  -framework CoreAudio -framework CoreFoundation Driver/JunctionDriver.c -o "$tmp/JunctionDriver.driver/Contents/MacOS/JunctionDriver"
sed -e "s/__VERSION__/$(cat Driver/VERSION)/" -e "s/__BUILD__/1/" Driver/Info.plist > "$tmp/JunctionDriver.driver/Contents/Info.plist"
xcrun clang $sanitize -mmacosx-version-min=26.0 -O1 -Wall -Wno-four-char-constants -framework CoreAudio -framework CoreFoundation \
  Tests/DriverHarness/harness.c -o "$tmp/harness"
TMPDIR="$tmp" "$tmp/harness" "$tmp/JunctionDriver.driver" "$(cat Driver/VERSION)"

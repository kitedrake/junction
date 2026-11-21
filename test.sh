#!/bin/sh
# Runs the engine tests, a stress test of the render kernel, then the driver harness: the kernel and the driver are
# built with address and undefined-behaviour sanitizers, and the driver is loaded into a test process with a
# stand-in host. Nothing is installed.
set -eu
cd "$(dirname "$0")"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# Inside another sandbox SwiftPM's own one can't start: turn it off there (see build.sh).
spm_flags=""
if ! /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null; then spm_flags="--disable-sandbox"; fi
xcrun swift test $spm_flags "$@"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/junction-harness.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
sanitize="-fsanitize=address,undefined -fno-omit-frame-pointer -g"
# The render kernel's sample-rate converter under the same sanitizers: random buffer sizes, stalls and rates.
xcrun clang $sanitize -mmacosx-version-min=26.0 -O1 -Wall -Wextra -Werror -ISources/JunctionKernel/include -framework CoreAudio -framework AudioToolbox \
  Sources/JunctionKernel/*.c Tests/KernelHarness/stress.c -o "$tmp/kernel-stress"
"$tmp/kernel-stress"
mkdir -p "$tmp/JunctionDriver.driver/Contents/MacOS" "$tmp/JunctionDriver.driver/Contents/Resources"
cp Driver/Icons/*.icns "$tmp/JunctionDriver.driver/Contents/Resources/"
xcrun clang $sanitize -mmacosx-version-min=26.0 -bundle -O1 -Wall -Wextra -Werror -Wno-four-char-constants -fvisibility=hidden \
  -framework CoreAudio -framework CoreFoundation Driver/JunctionDriver.c -o "$tmp/JunctionDriver.driver/Contents/MacOS/JunctionDriver"
sed -e "s/__VERSION__/$(cat Driver/VERSION)/" -e "s/__BUILD__/1/" Driver/Info.plist > "$tmp/JunctionDriver.driver/Contents/Info.plist"
xcrun clang $sanitize -mmacosx-version-min=26.0 -O1 -Wall -Wno-four-char-constants -framework CoreAudio -framework CoreFoundation \
  Tests/DriverHarness/harness.c -o "$tmp/harness"
TMPDIR="$tmp" "$tmp/harness" "$tmp/JunctionDriver.driver" "$(cat Driver/VERSION)"

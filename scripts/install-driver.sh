#!/bin/sh
# Installs JunctionDriver.driver into /Library/Audio/Plug-Ins/HAL and restarts Core Audio (all sound stops for a
# moment). Needs root: Junction runs it through macOS's administrator prompt; by hand:
#   sudo sh scripts/install-driver.sh build/JunctionDriver.driver
set -eu
src="${1:?usage: install-driver.sh path/to/JunctionDriver.driver}"
hal=/Library/Audio/Plug-Ins/HAL
dest="$hal/JunctionDriver.driver"
[ -f "$src/Contents/MacOS/JunctionDriver" ] || { echo "Not a Junction driver bundle: $src" >&2; exit 1; }
mkdir -p "$hal"
staging="$hal/.JunctionDriver.installing"
rm -rf "$staging"
ditto "$src" "$staging"
chown -R root:wheel "$staging"
chmod -R go-w "$staging"
xattr -dr com.apple.quarantine "$staging" 2>/dev/null || true
rm -rf "$dest"
mv "$staging" "$dest"
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod
echo "Installed $dest"

#!/bin/sh
# Removes Junction's driver and restarts Core Audio. Its virtual devices disappear; Junction's saved setup stays.
#   sudo sh scripts/uninstall-driver.sh
set -eu
dest=/Library/Audio/Plug-Ins/HAL/JunctionDriver.driver
if [ -d "$dest" ]; then
  rm -rf "$dest"
  launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod
  echo "Removed $dest"
else
  echo "Not installed: $dest"
fi

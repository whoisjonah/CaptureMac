#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/build-app.sh

destination="/Applications/CaptureMac.app"
if pgrep -x CaptureMac >/dev/null; then
  osascript -e 'tell application id "com.whoisjonah.CaptureMac" to quit' >/dev/null 2>&1 || pkill -x CaptureMac || true
  sleep 1
fi

if [[ -w /Applications ]]; then
  rm -rf "$destination"
  ditto build/CaptureMac.app "$destination"
else
  sudo rm -rf "$destination"
  sudo ditto build/CaptureMac.app "$destination"
fi

open "$destination"
echo "Local install successful"

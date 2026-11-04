#!/bin/bash
set -euo pipefail

repo="whoisjonah/CaptureMac"
destination="/Applications/CaptureMac.app"

major=$(sw_vers -productVersion | cut -d. -f1)
if (( major < 15 )); then
  echo "CaptureMac supports macOS 15 or higher. Sorry." >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "downloading..."
curl -fL --progress-bar "https://github.com/$repo/releases/latest/download/CaptureMac.zip" -o "$work/CaptureMac.zip"
ditto -x -k "$work/CaptureMac.zip" "$work"

if pgrep -x CaptureMac >/dev/null; then
  osascript -e 'tell application id "com.whoisjonah.CaptureMac" to quit' >/dev/null 2>&1 || pkill -x CaptureMac || true
  sleep 1
fi

if [[ -w /Applications ]]; then
  rm -rf "$destination"
  ditto "$work/CaptureMac.app" "$destination"
else
  echo "Please enter you password so that we can install CaptureMac to /Applications"
  sudo rm -rf "$destination"
  sudo ditto "$work/CaptureMac.app" "$destination"
fi

xattr -dr com.apple.quarantine "$destination" 2>/dev/null || true
open "$destination"
echo "CaptureMac is now installed - welcome :)"

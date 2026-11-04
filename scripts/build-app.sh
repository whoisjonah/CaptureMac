#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh

version="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
version="${version:-0.1.0}"
build="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
archs="${ARCHS:-$(uname -m)}"
identity="${SIGN_IDENTITY:-}"

if [[ -z "$identity" ]] && security find-certificate -c "CaptureMac Local" >/dev/null 2>&1; then
  identity="CaptureMac Local"
fi

binaries=()
for arch in $archs; do
  echo "building $arch"
  swift build -c release --arch "$arch" --product CaptureMac
  binaries+=("$(swift build -c release --arch "$arch" --show-bin-path)/CaptureMac")
done

app="build/CaptureMac.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

if [[ ${#binaries[@]} -gt 1 ]]; then
  lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/CaptureMac"
else
  cp "${binaries[0]}" "$app/Contents/MacOS/CaptureMac"
fi

cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
sed -e "s/{{VERSION}}/$version/" -e "s/{{BUILD}}/$build/" Resources/Info.plist > "$app/Contents/Info.plist"

if [[ -n "$identity" ]]; then
  echo "signing with $identity"
  codesign --force --sign "$identity" --identifier com.whoisjonah.CaptureMac --timestamp=none "$app"
else
  echo "signing ad hoc (run scripts/setup-signing.sh once or macos keeps re-asking for permissions)"
  codesign --force --sign - --identifier com.whoisjonah.CaptureMac "$app"
fi

echo "built $app ($version)"

#!/bin/zsh
# Build Air.app from the command line (no Xcode project needed).
#   ./build.sh            -> builds macos/Air/build/Air.app
#   ./build.sh --install  -> also copies it to /Applications/Air.app
# Environment: AIR_ARIA_PYTHON (mlx-audio/mlx-lm venv, default ~/Library/Application Support/Air/venv-smart/bin/python)
set -euo pipefail
# SwiftUI macros (@State) need the full Xcode toolchain, not just the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
HERE="${0:A:h}"
REPO="${HERE:h:h}"
BUILD="$HERE/build"
APP="$BUILD/Air.app"
ARIA_PYTHON="${AIR_ARIA_PYTHON:-$HOME/Library/Application Support/Air/venv-smart/bin/python}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/server"

echo "==> Compiling Swift"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/Air" "$HERE"/Sources/*.swift \
  -framework AppKit -framework SwiftUI -framework WebKit -framework AVFoundation -framework ScreenCaptureKit -framework Vision

echo "==> Resources"
sed -e "s#__ARIA_PYTHON__#${ARIA_PYTHON}#" "$HERE/Resources/Info.plist" > "$APP/Contents/Info.plist"
cp -R "$HERE/Resources/ui" "$APP/Contents/Resources/ui"
cp "$HERE"/server/*.py "$APP/Contents/Resources/server/"
cp "$HERE/Resources/personas.json" "$APP/Contents/Resources/personas.json"

echo "==> Icon"
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
mkdir -p "$BUILD/iconsrc" && cp "$HERE/make_icon.swift" "$BUILD/iconsrc/main.swift"
xcrun swiftc -O -target arm64-apple-macos14.0 -o "$BUILD/make_icon" "$BUILD/iconsrc/main.swift" "$HERE/Sources/Theme.swift" \
  -framework AppKit -framework SwiftUI
"$BUILD/make_icon" "$BUILD/icon_1024.png" aurora
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$BUILD/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# A stable local identity keeps macOS permissions (Screen Recording, Calendar...) across rebuilds.
# Create it once with ./make_signing_identity.sh; without it, Air is signed ad hoc.
IDENTITY="Air Local Code Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "==> Signing ($IDENTITY)"
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "==> Signing (ad hoc; run ./make_signing_identity.sh to keep permissions across rebuilds)"
  codesign --force --deep --sign - "$APP"
fi

if [[ "${1:-}" == "--install" ]]; then
  echo "==> Installing to /Applications/Air.app"
  if pgrep -x Air >/dev/null; then echo "Quit Air first."; exit 1; fi
  rm -rf /Applications/Air.app
  cp -R "$APP" /Applications/Air.app
  touch /Applications/Air.app
fi
echo "Built $APP"

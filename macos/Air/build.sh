#!/bin/zsh
# Build Air.app from the command line (no Xcode project needed).
#   ./build.sh            -> builds macos/Air/build/Air.app
#   ./build.sh --install  -> also copies it to /Applications/Air.app
# Environment: AIR_MYRA_PYTHON=/path/to/venv/bin/python (default: ~/personaplex-mlx/.venv/bin/python)
set -euo pipefail
# SwiftUI macros (@State) need the full Xcode toolchain, not just the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
HERE="${0:A:h}"
REPO="${HERE:h:h}"
BUILD="$HERE/build"
APP="$BUILD/Air.app"
PYTHON="${AIR_MYRA_PYTHON:-$HOME/personaplex-mlx/.venv/bin/python}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/server" "$APP/Contents/Resources/python"

echo "==> Compiling Swift"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/Air" "$HERE"/Sources/*.swift \
  -framework AppKit -framework SwiftUI -framework WebKit -framework AVFoundation

echo "==> Resources"
sed "s#__PYTHON__#${PYTHON}#" "$HERE/Resources/Info.plist" > "$APP/Contents/Info.plist"
cp -R "$HERE/Resources/ui" "$APP/Contents/Resources/ui"
cp "$HERE"/server/*.py "$APP/Contents/Resources/server/"
rsync -a --exclude '__pycache__' "$REPO/personaplex_mlx" "$APP/Contents/Resources/python/"

echo "==> Icon"
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
xcrun swift "$HERE/make_icon.swift" "$BUILD/icon_1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$BUILD/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad hoc)"
codesign --force --deep --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
  echo "==> Installing to /Applications/Air.app"
  if pgrep -x Air >/dev/null || pgrep -x Myra >/dev/null; then echo "Quit Air (and the old Myra) first."; exit 1; fi
  rm -rf /Applications/Air.app
  # Air replaces the earlier Myra.app build (owner approved the rename).
  rm -rf /Applications/Myra.app
  cp -R "$APP" /Applications/Air.app
  touch /Applications/Air.app
fi
echo "Built $APP"

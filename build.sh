#!/bin/zsh
# Builds MacConvert.app (with its Finder extension) and a .dmg, using only the
# Xcode Command Line Tools plus Homebrew webp and lame. Usage: ./build.sh [--install]
set -euo pipefail
cd "${0:A:h}"

TARGET="arm64-apple-macos14.0"
WEBP="$(brew --prefix webp)"
LAME="$(brew --prefix lame)"
MPG123="$(brew --prefix mpg123)"
BUILD="build"
APP="$BUILD/MacConvert.app"
EXT="$APP/Contents/PlugIns/FinderExtension.appex"
SWIFTFLAGS=(-O -target "$TARGET" -swift-version 5)
SPARKLE="Vendor/Sparkle"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$EXT/Contents/MacOS"

echo "› Compiling app"
swiftc "${SWIFTFLAGS[@]}" -module-name MacConvert \
  -import-objc-header Sources/ConversionKit/CWebP.h -I "$WEBP/include" -I "$LAME/include" \
  -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  Sources/App/*.swift Sources/ConversionKit/**/*.swift Sources/Shared/*.swift \
  "$WEBP/lib/libwebp.a" "$WEBP/lib/libsharpyuv.a" "$LAME/lib/libmp3lame.a" "$MPG123/lib/libmpg123.a" -lz \
  -o "$APP/Contents/MacOS/MacConvert"

echo "› Compiling Finder extension"
swiftc "${SWIFTFLAGS[@]}" -module-name FinderExtension \
  Sources/FinderExtension/*.swift Sources/Shared/*.swift -framework FinderSync \
  -o "$EXT/Contents/MacOS/FinderExtension"

# FFmpeg ships as its own executable beside the app's (see Vendor/ffmpeg/README.md).
cp Vendor/ffmpeg/ffmpeg "$APP/Contents/MacOS/ffmpeg"
mkdir -p "$APP/Contents/Resources/Licenses"
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE/LICENSE.txt" "$APP/Contents/Resources/Licenses/Sparkle-MIT.txt"
cp Vendor/ffmpeg/LICENSE.txt "$APP/Contents/Resources/Licenses/FFmpeg-LGPL.txt"
cp "$LAME/COPYING" "$APP/Contents/Resources/Licenses/LAME-LGPL.txt"
cp "$MPG123/COPYING" "$APP/Contents/Resources/Licenses/mpg123-LGPL.txt"
cp "$WEBP/COPYING" "$APP/Contents/Resources/Licenses/libwebp-BSD.txt"
cp "$(brew --prefix libvpx)/LICENSE" "$APP/Contents/Resources/Licenses/libvpx-BSD.txt"
cp "$(brew --prefix opus)/COPYING" "$APP/Contents/Resources/Licenses/Opus-BSD.txt"

cp Resources/App-Info.plist "$APP/Contents/Info.plist"
cp Resources/Extension-Info.plist "$EXT/Contents/Info.plist"

echo "› Rendering icon"
ICONSET="$BUILD/AppIcon.iconset"; mkdir -p "$ICONSET"
# The newest image in Icon/ is the artwork; without one, the built-in icon is drawn.
ICON_ART=$(ls -t Icon/*.{png,jpg,jpeg}(N) 2>/dev/null | head -1)
swift scripts/make-icon.swift "$BUILD/icon.png" ${ICON_ART:+"$ICON_ART"}
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$BUILD/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signing ("Sign to Run Locally"): fine on this Mac. Distribution later
# swaps "-" for a Developer ID identity plus notarization.
echo "› Signing"
codesign --force --sign - --entitlements Resources/Extension.entitlements "$EXT"
codesign --force --sign - --deep "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP/Contents/MacOS/ffmpeg"
codesign --force --sign - "$APP"

echo "› Packaging dmg"
STAGE="$BUILD/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname MacConvert -srcfolder "$STAGE" -ov -format UDZO "$BUILD/MacConvert.dmg"

if [[ "${1:-}" == "--install" ]]; then
  echo "› Installing to /Applications"
  pkill -x MacConvert 2>/dev/null || true
  rm -rf /Applications/MacConvert.app
  cp -R "$APP" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/MacConvert.app
  pluginkit -a /Applications/MacConvert.app/Contents/PlugIns/FinderExtension.appex
  open /Applications/MacConvert.app
  echo "  Relaunch Finder (Option-right-click its Dock icon → Relaunch) to load the updated extension."
fi
echo "✓ $BUILD/MacConvert.dmg"

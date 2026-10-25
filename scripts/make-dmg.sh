#!/bin/zsh
# Builds a styled, compressed installer disk image: build/MacConvert-<version>.dmg
# Usage: scripts/make-dmg.sh   (runs ./build.sh first if there's no app yet)
set -euo pipefail
cd "${0:A:h}/.."

APP=build/MacConvert.app
[[ -d $APP ]] || ./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
NAME="MacConvert"
STAGE=build/dmg-stage
RW=build/MacConvert-rw.dmg
OUT=build/MacConvert-$VERSION.dmg

echo "› Staging"
rm -rf "$STAGE" "$RW"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "Resources/How to Install.txt" "$STAGE/"
swift scripts/dmg-background.swift "$STAGE/.background/bg.png" 1
swift scripts/dmg-background.swift "$STAGE/.background/bg@2x.png" 2
tiffutil -cathidpicheck "$STAGE/.background/bg.png" "$STAGE/.background/bg@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null
rm "$STAGE/.background/"bg*.png
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

echo "› Laying out the window"
# A previous copy still mounted would take the volume name.
[[ -d "/Volumes/$NAME" ]] && hdiutil detach -quiet "/Volumes/$NAME" || true
hdiutil create -quiet -srcfolder "$STAGE" -volname "$NAME" -fs HFS+ -format UDRW -ov "$RW"
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/Apple_HFS/ {print $1}')
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 528}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 96
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "MacConvert.app" of container window to {150, 185}
        set position of item "Applications" of container window to {450, 185}
        set position of item "How to Install.txt" of container window to {300, 308}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
# Show the custom volume icon (when the developer tool is available).
command -v SetFile >/dev/null && SetFile -a C "/Volumes/$NAME" || true
sync
hdiutil detach -quiet "$DEVICE"

echo "› Compressing"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT"
rm -f "$RW"
rm -rf "$STAGE"
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"

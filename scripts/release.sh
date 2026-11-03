#!/bin/zsh
# Publishes the version in Resources/App-Info.plist: builds the DMG, creates the GitHub release,
# signs the DMG with the Sparkle key in your Keychain and adds it to appcast.xml, which the
# installed apps check. Commit and push your changes first. Usage: scripts/release.sh "What's new"
set -euo pipefail
cd "${0:A:h}/.."
NOTES="${1:?Usage: scripts/release.sh \"What's new\"}"
PLIST=Resources/App-Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" $PLIST)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" $PLIST)
DMG="build/MacConvert-$VERSION.dmg"
REPO=marchingsaints/maconvert

[[ -z "$(git status --porcelain)" ]] || { echo "Uncommitted changes: commit and push first." >&2; exit 1; }
git push -q
./build.sh >/dev/null && scripts/make-dmg.sh >/dev/null

gh release create "v$VERSION" "$DMG" --repo $REPO --target main --title "MacConvert $VERSION" --notes "$NOTES"

SIG=$(Vendor/Sparkle/bin/sign_update "$DMG")   # prints: sparkle:edSignature="…" length="…"
ITEM="    <item>
      <title>Version $VERSION</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <description><![CDATA[$NOTES]]></description>
      <enclosure url=\"https://github.com/$REPO/releases/download/v$VERSION/MacConvert-$VERSION.dmg\" $SIG type=\"application/octet-stream\"/>
    </item>"

[[ -f appcast.xml ]] || cat > appcast.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MacConvert</title>
<!--ITEMS-->
  </channel>
</rss>
XML
python3 - "$ITEM" <<'PY'
import sys
s = open("appcast.xml").read()
s = s.replace("<!--ITEMS-->", "<!--ITEMS-->\n" + sys.argv[1], 1)
open("appcast.xml", "w").write(s)
PY
git add appcast.xml
git commit -q -m "Appcast: $VERSION" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
git push -q
echo "✓ Released $VERSION: installed apps will find it within a day."

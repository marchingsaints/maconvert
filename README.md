# MacConvert

Right-click an image, video, audio file or PDF in Finder → **Convert to ▸**, **Optimize for Web…**, **Compress Video…**, **Compress PDF…** or (with several images/PDFs selected) **Combine into PDF…** → a small panel with the right options → the new file is saved next to the original. Everything runs locally.

- **Images:** WebP, JPEG, PNG, HEIC, PDF, TIFF, GIF, BMP
- **Video:** reads MOV, MP4, MKV, WebM, AVI, WMV, FLV, MPG, TS and more; writes MP4 (H.264), HEVC, WebM (VP9), MOV, MKV, GIF, or just the sound. Container-only changes are instant and lossless
- **Audio:** reads MP3, M4A, WAV, AIFF, FLAC, OGG, Opus, WMA…; writes MP3, M4A, FLAC, WAV, AIFF
- **PDF:** compress (pictures only, text stays sharp); → **Word (.docx)** with headings, lists, tables, images, columns, headers/footers and OCR for scans; → **PowerPoint** (a slide per page); → images; → text; combine images and PDFs
- **Office → PDF:** Word, Excel, PowerPoint, Pages, Keynote and Numbers files, exported by the app that made them

Also: drop files on the menu bar icon; hide a long conversion and get a notification when it's done; Settings for where files are saved (beside the original, a folder, or ask), showing them in Finder, open at login and the menu bar icon; a Recent menu.

## Build

Needs the Xcode Command Line Tools and Homebrew's `webp` and `lame` (`brew install webp lame`). FFmpeg is prebuilt in `Vendor/ffmpeg` (see its README for how to rebuild it).

```bash
./build.sh            # → build/MacConvert.app and build/MacConvert.dmg
./build.sh --install  # also copies to /Applications and launches it
scripts/make-dmg.sh   # → build/MacConvert-<version>.dmg, a styled installer to share
```

After installing an update, relaunch Finder (Option-right-click its Dock icon → Relaunch) so it loads the new extension.

On first launch, click **Turn On** to enable the Finder extension (or tick MacConvert in System Settings → Privacy & Security → Extensions → Added Extensions).

## Layout

| Path | What |
|---|---|
| `Sources/Shared` | Format catalog and the Finder → app handoff URL (`macconvert://run?…`), compiled into both targets |
| `Sources/FinderExtension` | Builds the right-click menu, then hands the selection to the app |
| `Sources/ConversionKit` | ImageIO + libwebp for images; AVFoundation for video (passthrough or re-encode, HDR-aware) and GIFs; AVFoundation, Core Audio (FLAC) and LAME (MP3) for audio; PDFKit + a Quartz filter for PDFs; batch runner |
| `Sources/ConversionKit/PDFToWord` | PDF → Word: page reader (text, rules, images, OCR), layout analysis (reading order, columns, tables, lists, headings), DOCX writer |
| `Vendor/ffmpeg` | Bundled LGPL FFmpeg for formats macOS can't handle |
| `Sources/App` | Menu bar agent, floating panel (SwiftUI), onboarding |

## Distribution later

Signing is ad-hoc (runs on this Mac only). To share it: get a Developer ID, swap `--sign -` in `build.sh` for that identity with `--options runtime`, notarize with `xcrun notarytool`, and build libwebp/LAME as universal binaries so Intel Macs work too. LAME is LGPL: ship it as a dynamic library (or the app's object files) to stay compliant.

## Updates

Installed copies check `appcast.xml` (published from this repo) once a day with [Sparkle](https://sparkle-project.org) and offer to install newer releases. To publish one: bump the version in `Resources/App-Info.plist`, commit and push, then run `scripts/release.sh "What's new"`. The update-signing key lives in the maintainer's Keychain (`Vendor/Sparkle/bin/generate_keys -x file` exports a backup).

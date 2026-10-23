#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/NativePreview build/module-cache
compile=(-fobjc-arc -fmodules -fmodules-cache-path="$PWD/build/module-cache" -mmacosx-version-min=14.0)
xcrun clang "${compile[@]}" -c AudioPlugin/Extension/CutdownAudioUnitFactory.m -o build/NativePreview/Factory.o
xcrun clang "${compile[@]}" -c AudioPlugin/Extension/CutdownReviewConnection.m -o build/NativePreview/Connection.o
xcrun clang "${compile[@]}" -c AudioPlugin/Preview/main.m -o build/NativePreview/Preview.o
xcrun clang++ -std=c++20 "${compile[@]}" \
    -framework Foundation -framework AudioToolbox -framework AVFoundation -framework CoreAudioKit -framework AppKit -framework UniformTypeIdentifiers \
    AudioPlugin/Extension/CutdownAudioUnit.mm build/NativePreview/{Factory,Connection,Preview}.o \
    -o build/NativePreview/Preview
bundle="build/NativePreview/Silent Snip UI Preview.app"
mkdir -p "$bundle/Contents/MacOS"
cp build/NativePreview/Preview "$bundle/Contents/MacOS/Preview"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.silentsnip.uipreview</string>
<key>CFBundleName</key><string>Silent Snip UI Preview</string>
<key>CFBundleExecutable</key><string>Preview</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ "${1:-}" != "--build-only" ]]; then build/NativePreview/Preview "$@"; fi

#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
swift_options+=(-c release)
swift build "${swift_options[@]}"
bin="$(swift build "${swift_options[@]}" --show-bin-path)"
app="$PWD/build/Figma Finder Bridge.app"
if [ -d "$app" ]; then
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")"
    [ "$bundle_id" = "com.behlock.figma-finder-bridge" ] || { printf '%s\n' 'Unexpected app in build output; refusing to replace it.' >&2; exit 1; }
    rm -rf "$app"
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/FigmaFinder" "$app/Contents/MacOS/FigmaFinder"
cp App/Info.plist "$app/Contents/Info.plist"
cp NOTICE "$app/Contents/Resources/NOTICE"
mkdir -p "$app/Contents/Resources/receiver"
cp receiver/manifest.json receiver/code.js receiver/ui.html "$app/Contents/Resources/receiver/"
codesign --force --sign - "$app"
printf '%s\n' "$app"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
options=(--disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -c release -debug-info-format none)
swift build "${options[@]}"
bin="$(swift build "${options[@]}" --show-bin-path)"
app="$PWD/build/Figma Finder Bridge.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/FigmaFinder" "$app/Contents/MacOS/FigmaFinder"
cp App/Info.plist "$app/Contents/Info.plist"
cp NOTICE "$app/Contents/Resources/NOTICE"
codesign --force --sign - "$app"
printf '%s\n' "$app"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh
application_directory="${1:-$HOME/Applications}"
destination="$application_directory/Figma Finder Bridge.app"
if [ -e "$destination" ]; then
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist")"
    [ "$bundle_id" = "com.behlock.figma-finder-bridge" ] || { printf '%s\n' 'Another app exists at the destination; refusing to overwrite it.' >&2; exit 1; }
fi
mkdir -p "$application_directory"
ditto 'build/Figma Finder Bridge.app' "$destination"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"
printf 'Installed %s\nOpen it once, then import its receiver manifest in Figma Desktop.\n' "$destination"

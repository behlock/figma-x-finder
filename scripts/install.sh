#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
swift scripts/stop-app.swift
bash scripts/build-app.sh
application_directory="${1:-$HOME/Applications}"
destination="$application_directory/$app_name.app"
verify_app "$destination"
mkdir -p "$application_directory"
if [ "$(cd "$application_directory" && pwd)/$app_name.app" != "$PWD/build/$app_name.app" ]; then
    replace_app "build/$app_name.app" "$destination"
fi
launch_services=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for legacy in "$application_directory/Figma Finder Bridge.app" "$PWD/build/Figma Finder Bridge.app"; do
    if [ -d "$legacy" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$legacy/Contents/Info.plist")" = "$app_bundle_id" ]; then
        "$launch_services" -u "$legacy" >/dev/null 2>&1 || true
        rm -rf "$legacy"
    fi
done
if [ "$(cd "$application_directory" && pwd)/$app_name.app" != "$PWD/build/$app_name.app" ]; then
    "$launch_services" -u "$PWD/build/$app_name.app" >/dev/null 2>&1 || true
fi
"$launch_services" -f "$destination"
printf 'Installed %s\nOpen it once, then import its receiver manifest in Figma Desktop.\n' "$destination"

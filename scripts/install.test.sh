#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/source.app"
printf old > "$fixture/source.app/version"
replace_app "$fixture/source.app" "$fixture/installed.app"
cmp "$fixture/source.app/version" "$fixture/installed.app/version"
cp "$fixture/installed.app/version" "$fixture/original"
printf new > "$fixture/source.app/version"
ditto() { return 1; }
if replace_app "$fixture/source.app" "$fixture/installed.app"; then exit 1; fi
cmp "$fixture/original" "$fixture/installed.app/version"
unset -f ditto
mv() {
    case "$1" in */new.app) return 1;; esac
    command mv "$@"
}
if replace_app "$fixture/source.app" "$fixture/installed.app"; then exit 1; fi
cmp "$fixture/original" "$fixture/installed.app/version"
unset -f mv
replace_app "$fixture/source.app" "$fixture/installed.app"
cmp "$fixture/source.app/version" "$fixture/installed.app/version"
mkdir -p "$fixture/other.app/Contents"
cp App/Info.plist "$fixture/other.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier org.example.other' "$fixture/other.app/Contents/Info.plist"
if verify_app "$fixture/other.app" 2>/dev/null; then exit 1; fi
printf 'Installer replacement checks passed.\n'

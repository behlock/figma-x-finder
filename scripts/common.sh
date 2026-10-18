cd "$(dirname "${BASH_SOURCE[0]}")/.."
app_name="$(/usr/libexec/PlistBuddy -c 'Print CFBundleName' App/Info.plist)"
app_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' App/Info.plist)"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift_options=(--disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -debug-info-format none)

verify_app() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$1/Contents/Info.plist")" = "$app_bundle_id" ] || {
            printf 'Refusing to replace another app: %s\n' "$1" >&2
            return 1
        }
    fi
}

replace_app() (
    staging="$(mktemp -d "${2}.XXXXXX")" || exit 1
    trap 'rm -rf "$staging/new.app"; rmdir "$staging" 2>/dev/null || true' EXIT
    ditto "$1" "$staging/new.app" || exit 1
    if [ -e "$2" ]; then mv "$2" "$staging/previous.app" || exit 1; fi
    if ! mv "$staging/new.app" "$2"; then
        if [ -e "$staging/previous.app" ]; then mv "$staging/previous.app" "$2" || exit 1; fi
        exit 1
    fi
    rm -rf "$staging/previous.app"
)

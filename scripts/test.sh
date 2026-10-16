#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
swift test "${swift_options[@]}"
node --test receiver/code.test.js receiver/ui.test.js
plutil -lint App/Info.plist

#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK=$(mktemp -d /private/tmp/tokens-prep-check.XXXXXX)
xcrun swiftc -module-cache-path "$WORK/modules" \
  "$ROOT/validation/WidgetSmoke/Sources/Shared.swift" \
  "$ROOT/validation/WidgetSmoke/Tests/Checks.swift" -o "$WORK/checks"
"$WORK/checks"

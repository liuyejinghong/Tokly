#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK=$(mktemp -d /private/tmp/tokens-shared-check.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -target arm64-apple-macos14.0 -module-cache-path "$WORK/modules" \
  "$ROOT/Shared/UsageSnapshot.swift" "$ROOT/Shared/UsageAggregation.swift" \
  "$ROOT/Shared/WidgetSnapshot.swift" "$ROOT/Shared/Tests/Checks.swift" -o "$WORK/checks"
"$WORK/checks" "$ROOT/Shared/sample-snapshot.json"

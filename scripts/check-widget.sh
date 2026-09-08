#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK=$(mktemp -d /private/tmp/tokens-widget-check.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -target arm64-apple-macos14.0 -module-cache-path "$WORK/modules" \
  "$ROOT/Shared/UsageSnapshot.swift" "$ROOT/Shared/UsageAggregation.swift" "$ROOT/Shared/WidgetSnapshot.swift" \
  "$ROOT/TokensWidget/WidgetData.swift" "$ROOT/TokensWidget/Tests/Checks.swift" -o "$WORK/checks"
"$WORK/checks" "$ROOT/Shared/sample-snapshot.json"
xcodebuild -project "$ROOT/Tokly.xcodeproj" -scheme Tokly -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ROOT/.build/TokensDerivedData" \
  CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=14.0 build

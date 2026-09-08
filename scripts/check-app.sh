#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK=$(mktemp -d /private/tmp/tokens-app-check.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -target arm64-apple-macos14.0 -module-cache-path "$WORK/modules" \
  "$ROOT/TokensApp/ScanScheduler.swift" "$ROOT/TokensApp/Tests/Checks.swift" -o "$WORK/checks"
"$WORK/checks"
xcrun swiftc -target arm64-apple-macos14.0 -module-cache-path "$WORK/modules" \
  "$ROOT/TokensApp/Tests/RunnerFixture.swift" -o "$WORK/runner-fixture"
xcrun swiftc -target arm64-apple-macos14.0 -module-cache-path "$WORK/modules" \
  "$ROOT/TokensApp/CollectorRunner.swift" "$ROOT/TokensApp/Tests/RunnerChecks.swift" -o "$WORK/runner-checks"
"$WORK/runner-checks" "$WORK/runner-fixture"
xcrun swiftc -target arm64-apple-macos14.0 -module-cache-path "$WORK/modules" \
  "$ROOT/Shared/UsageSnapshot.swift" "$ROOT/Shared/UsageAggregation.swift" "$ROOT/Shared/WidgetSnapshot.swift" \
  "$ROOT/TokensApp/RangeProjection.swift" "$ROOT/TokensApp/Tests/ProjectionChecks.swift" -o "$WORK/projection-checks"
"$WORK/projection-checks" "$ROOT/Shared/sample-snapshot.json"
xcodebuild -project "$ROOT/Tokens.xcodeproj" -scheme Tokens -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ROOT/.build/TokensDerivedData" \
  CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=14.0 build

#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PROJECT="$ROOT/validation/WidgetSmoke/TokensPrep.xcodeproj"
CONFIG="$ROOT/validation/WidgetSmoke/Config/Local.xcconfig"
DERIVED="$ROOT/validation/WidgetSmoke/DerivedData"
if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo "完整 Xcode 未找到：$DEVELOPER_DIR" >&2
  exit 1
fi
if [[ ! -f "$CONFIG" ]]; then
  echo "请先从 Local.xcconfig.example 创建 Local.xcconfig 并设置 Team ID。" >&2
  exit 1
fi
case "${1:-build}" in
  check)
    xcodebuild -version
    xcodebuild -checkFirstLaunchStatus
    xcodebuild -list -project "$PROJECT" -derivedDataPath "$DERIVED" -scheme TokensPrep
    ;;
  compile)
    xcodebuild -project "$PROJECT" -scheme TokensPrep -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DERIVED" -xcconfig "$CONFIG" CODE_SIGNING_ALLOWED=NO build
    ;;
  build)
    xcodebuild -project "$PROJECT" -scheme TokensPrep -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DERIVED" -xcconfig "$CONFIG" build
    ;;
  *) echo "usage: $0 [check|compile|build]" >&2; exit 2;;
esac

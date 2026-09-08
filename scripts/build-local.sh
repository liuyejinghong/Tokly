#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="$ROOT/Config/Local.xcconfig"
BUILD_CONFIGURATION="${1:-Release}"
case "$BUILD_CONFIGURATION" in Release|Debug) ;; *) echo "Use Release or Debug" >&2; exit 2;; esac
python3 "$ROOT/scripts/version.py" check
SOURCE_COMMIT=$(git -C "$ROOT" rev-parse HEAD)
if [[ ! -f "$CONFIG" ]]; then
  echo 'Create Config/Local.xcconfig from its example before a signed local build.' >&2
  exit 1
fi
xcodebuild -project "$ROOT/Tokly.xcodeproj" -scheme Tokly -configuration "$BUILD_CONFIGURATION" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ROOT/.build/TokensSigned" \
  -xcconfig "$CONFIG" CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY='Apple Development' TOKLY_GIT_COMMIT="$SOURCE_COMMIT" MACOSX_DEPLOYMENT_TARGET=14.0 build

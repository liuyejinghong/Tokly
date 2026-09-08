#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="$ROOT/Config/Local.xcconfig"
if [[ ! -f "$CONFIG" ]]; then
  echo 'Create Config/Local.xcconfig from its example before a signed local build.' >&2
  exit 1
fi
xcodebuild -project "$ROOT/Tokens.xcodeproj" -scheme Tokens -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ROOT/.build/TokensSigned" \
  -xcconfig "$CONFIG" CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY='Apple Development' MACOSX_DEPLOYMENT_TARGET=14.0 build

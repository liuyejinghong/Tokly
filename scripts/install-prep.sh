#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCE="$ROOT/validation/WidgetSmoke/DerivedData/Build/Products/Debug/TokensPrep.app"
DESTINATION="$HOME/Applications/TokensPrep.app"
EXPECTED=local.tokensmacos.preflight
[[ -d "$SOURCE" ]] || { echo '请先运行 scripts/xcode-prep.sh build' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SOURCE/Contents/Info.plist")" == "$EXPECTED" ]]
/usr/bin/codesign --verify --deep --strict "$SOURCE"
if [[ -L "$DESTINATION" ]]; then
  echo '拒绝覆盖符号链接目标。' >&2; exit 1
fi
if [[ -e "$DESTINATION" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DESTINATION/Contents/Info.plist")" == "$EXPECTED" ]] || {
    echo '拒绝覆盖其他应用。' >&2; exit 1
  }
fi
mkdir -p "$HOME/Applications"
/usr/bin/ditto "$SOURCE" "$DESTINATION"
/usr/bin/codesign --verify --deep --strict "$DESTINATION"
echo "$DESTINATION"

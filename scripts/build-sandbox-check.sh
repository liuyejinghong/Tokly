#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP="$ROOT/.build/SandboxAccess/ToklySandboxCheck.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 \
  -module-cache-path "$ROOT/.build/swift-sandbox-modules" \
  "$ROOT/validation/SandboxAccess/Sources/SandboxCheck.swift" -o "$APP/Contents/MacOS/ToklySandboxCheck"
cp "$ROOT/.build/collector-target/release/tokens-collector" "$APP/Contents/MacOS/tokens-collector"
python3 - "$APP" "$ROOT" <<'PY'
import plistlib,sys
from pathlib import Path
app,root=map(Path,sys.argv[1:])
d={'CFBundleIdentifier':'local.tokensmacos.sandboxcheck','CFBundleExecutable':'ToklySandboxCheck','CFBundleName':'Tokly Sandbox Check','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'0.1.0','LSMinimumSystemVersion':'14.0','NSPrincipalClass':'NSApplication','ProbeDeniedHome':str(root/'validation/SandboxAccess/Fixtures/denied-home')}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(d))
PY
codesign --force --sign 'Apple Development' --options runtime \
  --entitlements "$ROOT/validation/SandboxAccess/Helper.entitlements" "$APP/Contents/MacOS/tokens-collector"
codesign --force --sign 'Apple Development' --options runtime \
  --entitlements "$ROOT/validation/SandboxAccess/App.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

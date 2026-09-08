#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="$ROOT/Config/Local.xcconfig"
DERIVED="${TOKLY_STORE_DERIVED:-$ROOT/.build/ToklyStoreCheck}"
STORE_CONFIG="$ROOT/.build/StoreCheck.xcconfig"
printf '#include "%s"\nTOKENS_APP_GROUP = $(DEVELOPMENT_TEAM).tokensmacos.storecheck\n' "$CONFIG" > "$STORE_CONFIG"
python3 "$ROOT/scripts/version.py" check
mkdir -p "$ROOT/.build/store-helper"
cp "$ROOT/.build/store-collector-target/release/tokens-collector" "$ROOT/.build/store-helper/tokens-collector"
codesign --force --sign 'Apple Development' --options runtime \
 --entitlements "$ROOT/Config/StoreHelper.entitlements" "$ROOT/.build/store-helper/tokens-collector"
SOURCE_COMMIT=$(git -C "$ROOT" rev-parse HEAD)
xcodebuild -project "$ROOT/Tokly.xcodeproj" -scheme Tokly -configuration Release \
 -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
 -xcconfig "$STORE_CONFIG" CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY='Apple Development' \
 TOKLY_APP_BUNDLE_ID=local.tokensmacos.storecheck \
 TOKLY_APP_INFO=Config/StoreAppInfo.plist TOKLY_WIDGET_INFO=Config/StoreWidgetInfo.plist \
 TOKLY_APP_ENTITLEMENTS=Config/StoreApp.entitlements TOKLY_HELPER_PATH=.build/store-helper/tokens-collector \
 TOKLY_GIT_COMMIT="$SOURCE_COMMIT" MACOSX_DEPLOYMENT_TARGET=14.0 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build

python3 - "$DERIVED/Build/Products/Release/Tokly.app" <<'PYCODE'
from pathlib import Path
import plistlib,sys
app=Path(sys.argv[1])
a=plistlib.loads((app/'Contents/Info.plist').read_bytes())
w=plistlib.loads((app/'Contents/PlugIns/ToklyWidget.appex/Contents/Info.plist').read_bytes())
assert a['CFBundleIdentifier']=='local.tokensmacos.storecheck'
assert w['CFBundleIdentifier']=='local.tokensmacos.storecheck.widget'
assert a['TokensAppGroupIdentifier']==w['TokensAppGroupIdentifier']
assert a['TokensAppGroupIdentifier'].endswith('.tokensmacos.storecheck')
assert a['ToklyURLScheme']==w['ToklyURLScheme']=='tokly-store-check'
print('PASS isolated Store Check bundle, group and URL identities')
PYCODE

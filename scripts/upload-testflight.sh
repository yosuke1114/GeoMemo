#!/usr/bin/env bash
# geomemo を Release ビルド → IPA エクスポート → TestFlight アップロードまで一括実行。
#
# 前提:
#  - Xcode 16.3+ がインストール済み
#  - キーチェーンに "Apple Distribution" 証明書が登録済み（Xcode → Settings → Accounts → Manage Certificates から発行可）
#  - ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 が配置済み
#  - 環境変数 ASC_KEY_ID / ASC_ISSUER_ID を export 済み、または以下のデフォルトでよい
#
# 使い方:
#   ./scripts/upload-testflight.sh

set -euo pipefail

# ----- 設定 -----
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

PROJECT="geomemo.xcodeproj"
SCHEME="geomemo"
ARCHIVE_PATH="build/geomemo.xcarchive"
EXPORT_PATH="build/export"
EXPORT_OPTIONS="ExportOptions.plist"

ASC_KEY_ID="${ASC_KEY_ID:-SZ4BRLB544}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-6ba25cb4-5846-4fda-81db-79890248e867}"
ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"

if [[ ! -f "$ASC_KEY_PATH" ]]; then
  echo "ERROR: ASC API key not found: $ASC_KEY_PATH" >&2
  echo "App Store Connect → Users and Access → Integrations から .p8 を発行してください" >&2
  exit 1
fi

AUTH=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$ASC_KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

# ----- 1. Clean & Archive -----
rm -rf build
mkdir -p build

echo "==> Archive (Release)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=iOS" \
  "${AUTH[@]}"

# ----- 2. Export IPA -----
echo "==> Export IPA"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  "${AUTH[@]}"

IPA="$(ls "$EXPORT_PATH"/*.ipa | head -1)"
if [[ -z "$IPA" ]]; then
  echo "ERROR: IPA not found under $EXPORT_PATH" >&2
  exit 1
fi
echo "    IPA: $IPA"

# ----- 3. Upload to TestFlight -----
echo "==> Upload to TestFlight"
xcrun altool --upload-app --type ios --file "$IPA" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo ""
echo "==> Done. App Store Connect → TestFlight で Processing 完了を待ってください（5〜15 分）"

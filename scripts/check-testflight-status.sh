#!/usr/bin/env bash
# TestFlight ビルドのステータスを App Store Connect API で取得する。
# 依存: Ruby stdlib（macOS 標準）。他プロジェクトでも symlink で再利用可。
#
# 環境変数（~/.zshrc などに export 推奨）:
#   ASC_KEY_ID      App Store Connect API Key ID（必須）
#   ASC_ISSUER_ID   Issuer ID（必須）
#   ASC_KEY_PATH    .p8 のパス（既定: ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8）
#
# 使い方:
#   ./scripts/check-testflight-status.sh                       # カレントから bundle ID 自動検出
#   ./scripts/check-testflight-status.sh -b com.foo.bar        # 明示指定
#   ./scripts/check-testflight-status.sh -n 20                 # 最新 20 件
#
# 別プロジェクトから使うなら:
#   ln -s "$PWD/scripts/check-testflight-status.sh" ~/.local/bin/asc-builds
#   chmod +x ~/.local/bin/asc-builds
#   asc-builds                                                 # どのプロジェクトディレクトリでも

set -euo pipefail

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# //; s/^#$//'
  exit 0
}

BUNDLE_ID="${BUNDLE_ID:-}"
LIMIT="${LIMIT:-10}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--bundle-id) BUNDLE_ID="$2"; shift 2;;
    -n|--limit)     LIMIT="$2"; shift 2;;
    -h|--help)      usage;;
    *) echo "Unknown arg: $1" >&2; usage;;
  esac
done

# --- Bundle ID 解決 ---
if [[ -z "$BUNDLE_ID" && -f project.yml ]]; then
  BUNDLE_ID=$(awk '/PRODUCT_BUNDLE_IDENTIFIER:/ {print $2; exit}' project.yml | tr -d '"')
fi
if [[ -z "$BUNDLE_ID" ]]; then
  PROJ=$(ls -d ./*.xcodeproj 2>/dev/null | head -1 || true)
  if [[ -n "$PROJ" ]]; then
    BUNDLE_ID=$(xcodebuild -project "$PROJ" -showBuildSettings -json 2>/dev/null | \
      ruby -rjson -e '
        s = STDIN.read
        d = JSON.parse(s)
        v = d.map { |e| e.dig("buildSettings", "PRODUCT_BUNDLE_IDENTIFIER") }.compact.first
        puts v.to_s
      ' 2>/dev/null || true)
  fi
fi
if [[ -z "$BUNDLE_ID" ]]; then
  echo "Bundle ID を特定できません。-b <id> または BUNDLE_ID 環境変数を指定してください。" >&2
  exit 1
fi

# --- 認証情報 ---
: "${ASC_KEY_ID:?ASC_KEY_ID env required}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID env required}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
if [[ ! -f "$ASC_KEY_PATH" ]]; then
  echo "API key not found: $ASC_KEY_PATH" >&2
  exit 1
fi

# --- Ruby で JWT 生成 + API 呼び出し ---
BUNDLE_ID="$BUNDLE_ID" LIMIT="$LIMIT" \
ASC_KEY_ID="$ASC_KEY_ID" ASC_ISSUER_ID="$ASC_ISSUER_ID" ASC_KEY_PATH="$ASC_KEY_PATH" \
ruby - <<'RUBY'
require 'openssl'; require 'json'; require 'base64'; require 'net/http'; require 'uri'

key = OpenSSL::PKey::EC.new(File.read(ENV['ASC_KEY_PATH']))
now = Time.now.to_i
hdr = { alg: 'ES256', kid: ENV['ASC_KEY_ID'], typ: 'JWT' }
pay = { iss: ENV['ASC_ISSUER_ID'], iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' }
b64 = ->(o) { Base64.urlsafe_encode64(JSON.dump(o), padding: false) }
si  = "#{b64.call(hdr)}.#{b64.call(pay)}"
der = key.sign(OpenSSL::Digest::SHA256.new, si)
a   = OpenSSL::ASN1.decode(der)
to_bin = ->(v) { v.to_s(2).rjust(32, "\x00".b) }
sig = Base64.urlsafe_encode64(to_bin.call(a.value[0].value) + to_bin.call(a.value[1].value), padding: false)
jwt = "#{si}.#{sig}"

def get(u, jwt)
  uri = URI(u)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  req = Net::HTTP::Get.new(uri.request_uri)
  req['Authorization'] = "Bearer #{jwt}"
  res = http.request(req)
  abort "HTTP #{res.code}: #{res.body}" unless res.is_a?(Net::HTTPSuccess)
  JSON.parse(res.body)
end

bundle = ENV['BUNDLE_ID']
limit  = ENV['LIMIT'].to_i
apps   = get("https://api.appstoreconnect.apple.com/v1/apps?filter[bundleId]=#{bundle}", jwt)
app    = apps['data'].first
abort "App not found for bundleId=#{bundle}" unless app
aid = app['id']

url = "https://api.appstoreconnect.apple.com/v1/builds?filter[app]=#{aid}&sort=-uploadedDate&limit=#{limit}&include=preReleaseVersion"
res = get(url, jwt)
inc = (res['included'] || []).each_with_object({}) { |i, h| h["#{i['type']}:#{i['id']}"] = i }

puts "App: #{app['attributes']['name']} (#{bundle})"
puts "--- Recent #{limit} builds (newest first) ---"
res['data'].each do |b|
  attrs = b['attributes']
  pre_id = b.dig('relationships', 'preReleaseVersion', 'data', 'id')
  pv = pre_id ? inc["preReleaseVersions:#{pre_id}"]&.dig('attributes', 'version') : nil
  printf "  %-8s (%-4s)  state=%-12s uploaded=%s\n",
         pv || '?', attrs['version'], attrs['processingState'], attrs['uploadedDate']
end
RUBY

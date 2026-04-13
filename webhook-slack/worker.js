/**
 * GeoMemo – App Store Connect Webhook → Slack Notifier
 * Cloudflare Workers で動作
 *
 * 環境変数（wrangler secret put で設定）:
 *   ASC_WEBHOOK_SECRET   ... App Store Connect Webhook に設定したシークレット
 *   SLACK_WEBHOOK_URL    ... Slack Incoming Webhook URL
 */

export default {
  async fetch(request, env) {
    // POST のみ受け付ける
    if (request.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    const rawBody = await request.text();

    // ── 1. シグネチャ検証（HMAC-SHA256）────────────────────────────────
    const signature = request.headers.get("x-apple-signature") ?? "";
    if (!(await verifySignature(rawBody, signature, env.ASC_WEBHOOK_SECRET))) {
      console.error("Signature verification failed");
      return new Response("Unauthorized", { status: 401 });
    }

    // ── 2. ペイロード解析 ───────────────────────────────────────────────
    let payload;
    try {
      payload = JSON.parse(rawBody);
    } catch {
      return new Response("Bad Request", { status: 400 });
    }

    // ── 3. Slack メッセージ生成 ─────────────────────────────────────────
    const message = buildSlackMessage(payload);
    if (!message) {
      // 対象外のイベントは無視
      return new Response("Ignored", { status: 200 });
    }

    // ── 4. Slack に送信 ─────────────────────────────────────────────────
    const slackRes = await fetch(env.SLACK_WEBHOOK_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(message),
    });

    if (!slackRes.ok) {
      console.error("Slack error:", await slackRes.text());
      return new Response("Slack Error", { status: 502 });
    }

    return new Response("OK", { status: 200 });
  },
};

// ── HMAC-SHA256 検証 ────────────────────────────────────────────────────────
async function verifySignature(body, signature, secret) {
  if (!secret || !signature) return false;
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(body));
  const expected = Array.from(new Uint8Array(mac))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return expected === signature.toLowerCase();
}

// ── Slack Block Kit メッセージ生成 ──────────────────────────────────────────
function buildSlackMessage(payload) {
  const type = payload.type ?? payload.eventType ?? "UNKNOWN";
  const data = payload.data ?? {};

  const appName = data.appName ?? data.name ?? "GeoMemo";
  const version = data.versionString ?? data.version ?? "";
  const versionLabel = version ? ` v${version}` : "";

  switch (type) {
    // ── App Store 審査ステータス変化 ────────────────────────────────────
    case "APP_STORE_VERSION_STATE_CHANGED": {
      const state = data.appVersionState ?? data.state ?? "";
      const { emoji, color, label } = stateInfo(state);
      return {
        text: `${emoji} *${appName}${versionLabel}* – ${label}`,
        attachments: [
          {
            color,
            blocks: [
              {
                type: "section",
                text: {
                  type: "mrkdwn",
                  text: `*${appName}${versionLabel}* の審査ステータスが変わりました\n\n${emoji} *${label}*`,
                },
              },
              {
                type: "context",
                elements: [
                  { type: "mrkdwn", text: `イベント: \`${type}\`` },
                ],
              },
            ],
          },
        ],
      };
    }

    // ── ビルドアップロード ───────────────────────────────────────────────
    case "BUILD_STATUS_CHANGED":
    case "BETA_BUILD_STATUS_CHANGED": {
      const status = data.processingState ?? data.status ?? "";
      const { emoji, color, label } = buildStatusInfo(status);
      const platform = data.platform ?? data.platformType ?? "";
      const build = data.version ?? data.buildNumber ?? "";
      return {
        text: `${emoji} *${appName}* ビルド ${build} – ${label}`,
        attachments: [
          {
            color,
            blocks: [
              {
                type: "section",
                text: {
                  type: "mrkdwn",
                  text: `*${appName}* のビルドステータスが変わりました\n\n${emoji} *${label}*\nビルド: \`${build}\`  プラットフォーム: ${platform}`,
                },
              },
            ],
          },
        ],
      };
    }

    // ── TestFlight フィードバック ────────────────────────────────────────
    case "TESTFLIGHT_FEEDBACK_RECEIVED": {
      const testerEmail = data.testerEmail ?? data.email ?? "不明";
      const feedbackText = data.text ?? data.body ?? "（本文なし）";
      const buildVer = data.buildVersion ?? data.buildNumber ?? "";
      return {
        text: `💬 *${appName}* に TestFlight フィードバックが届きました`,
        attachments: [
          {
            color: "#7C3AED",
            blocks: [
              {
                type: "section",
                text: {
                  type: "mrkdwn",
                  text: `💬 *TestFlight フィードバック – ${appName}*\nビルド: \`${buildVer}\`\nテスター: ${testerEmail}`,
                },
              },
              {
                type: "section",
                text: {
                  type: "mrkdwn",
                  text: `> ${feedbackText.slice(0, 500)}`,
                },
              },
            ],
          },
        ],
      };
    }

    // ── Ping（テスト送信）───────────────────────────────────────────────
    case "PING":
    case "TEST":
      return {
        text: "🔔 App Store Connect Webhook 接続テスト成功！",
        attachments: [
          {
            color: "#30A46C",
            blocks: [
              {
                type: "section",
                text: {
                  type: "mrkdwn",
                  text: "🔔 *Webhook 疎通確認*\nApp Store Connect → Cloudflare Workers → Slack の接続が正常に動作しています。",
                },
              },
            ],
          },
        ],
      };

    default:
      // 未対応イベントはログだけ残して 200 返却
      console.log("Unhandled event type:", type, JSON.stringify(payload));
      return null;
  }
}

// ── App Store 審査ステータス → 表示情報 ─────────────────────────────────────
function stateInfo(state) {
  const map = {
    APPROVED:                      { emoji: "✅", color: "#30A46C", label: "審査承認" },
    READY_FOR_SALE:                { emoji: "🚀", color: "#30A46C", label: "販売中" },
    PENDING_APPLE_RELEASE:         { emoji: "⏳", color: "#E5A000", label: "Apple リリース待ち" },
    PENDING_DEVELOPER_RELEASE:     { emoji: "⏳", color: "#E5A000", label: "開発者リリース待ち" },
    PROCESSING_FOR_APP_STORE:      { emoji: "⚙️",  color: "#E5A000", label: "App Store 処理中" },
    IN_REVIEW:                     { emoji: "🔍", color: "#3D3BF3", label: "審査中" },
    WAITING_FOR_REVIEW:            { emoji: "📬", color: "#3D3BF3", label: "審査待ち" },
    PREPARE_FOR_SUBMISSION:        { emoji: "📝", color: "#8E8E93", label: "申請準備中" },
    REJECTED:                      { emoji: "❌", color: "#E5484D", label: "リジェクト" },
    METADATA_REJECTED:             { emoji: "❌", color: "#E5484D", label: "メタデータリジェクト" },
    INVALID_BINARY:                { emoji: "⚠️", color: "#E5484D", label: "バイナリ無効" },
    DEVELOPER_REJECTED:            { emoji: "🔙", color: "#8E8E93", label: "開発者が取り下げ" },
    DEVELOPER_REMOVED_FROM_SALE:   { emoji: "🔒", color: "#8E8E93", label: "販売停止" },
  };
  return map[state] ?? { emoji: "ℹ️", color: "#8E8E93", label: state };
}

// ── ビルドステータス → 表示情報 ─────────────────────────────────────────────
function buildStatusInfo(status) {
  const map = {
    PROCESSING:       { emoji: "⚙️",  color: "#E5A000", label: "処理中" },
    FAILED:           { emoji: "❌", color: "#E5484D", label: "処理失敗" },
    INVALID:          { emoji: "⚠️", color: "#E5484D", label: "無効" },
    VALID:            { emoji: "✅", color: "#30A46C", label: "有効" },
    READY_TO_SUBMIT:  { emoji: "📬", color: "#3D3BF3", label: "申請可能" },
    APPROVED:         { emoji: "✅", color: "#30A46C", label: "承認済み" },
    REJECTED:         { emoji: "❌", color: "#E5484D", label: "リジェクト" },
  };
  return map[status] ?? { emoji: "ℹ️", color: "#8E8E93", label: status };
}

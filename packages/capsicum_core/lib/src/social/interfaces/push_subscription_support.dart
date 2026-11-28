/// サーバーがサードパーティアプリからの Web Push 登録を拒否した場合に投げる。
///
/// Misskey upstream は `/api/sw/register` を `secure: true` で制限しており
/// （GHSA-7pxq-6xx9-xpgm, 2023-12）、OAuth / MiAuth トークン経由では HTTP 400
/// と `{code: ACCESS_DENIED}` を返す。この種の「再試行しても成功しない」
/// 既知の仕様制約を呼び出し側に伝えるための型付き例外。
///
/// 呼び出し側（[PushRegistrationService]）は Sentry への転送を抑制し、
/// 登録フロー内でのロールバックだけを行う。
class PushRegistrationNotSupportedException implements Exception {
  PushRegistrationNotSupportedException(this.message);

  final String message;

  @override
  String toString() => 'PushRegistrationNotSupportedException: $message';
}

/// 利用者が種類ごとにプッシュ通知をオン / オフできる通知の分類 (#1411)。
///
/// ⚠ サーバーの通知の種類そのものではなく、**利用者に見せる分類**。Mastodon の
/// `data[alerts][<type>]` へはアダプターが写す（例: [follow] は `follow` と
/// `follow_request`、[update] は `update` と `quoted_update`）。ここに無い種類
/// （管理者からの警告・関係が失われた・新規登録・通報など）は常に受け取る。
enum PushAlertCategory {
  mention,
  favourite,
  reblog,
  follow,
  poll,
  status,
  update,
  quote,
}

/// Web Push サブスクリプションの登録・解除を行う Feature インターフェース。
///
/// Mastodon: POST /api/v1/push/subscription, DELETE /api/v1/push/subscription
/// Misskey: POST /api/sw/register, POST /api/sw/unregister
abstract mixin class PushSubscriptionSupport {
  /// サーバーの VAPID 公開鍵を取得する。
  ///
  /// Mastodon: GET /api/v2/instance → configuration.vapid.public_key
  /// Misskey: POST /api/meta → swPublickey
  Future<String?> getVapidPublicKey();

  /// Web Push サブスクリプションを登録する。
  ///
  /// [endpoint] リレーサーバーの受信 URL（例: `https://relay.capsicum.shrieker.net/push/<token>`）
  /// [p256dh] クライアント公開鍵（Base64URL エンコード）
  /// [auth] 認証シークレット（Base64URL エンコード）
  ///
  /// 戻り値: サーバーから返されたサブスクリプション情報（サーバー依存）。
  ///
  /// [mutedCategories] 利用者が切った通知の分類 (#1411)。サーバー側で送らなく
  /// させる。⚠ **絞る口を持たないサーバー（Misskey）は無視する**
  /// （[supportsPushAlertFilter] が false）。
  Future<Map<String, dynamic>> subscribePush({
    required String endpoint,
    required String p256dh,
    required String auth,
    Set<PushAlertCategory> mutedCategories = const {},
  });

  /// 通知の種類ごとに、サーバー側で送る / 送らないを絞れるか (#1411)。
  ///
  /// ⚠ Misskey の `sw/register` には絞る口が無く、payload は暗号化されていて
  /// relay も種類を見られない。端末で捨てるには iOS の NSE に特別な entitlement
  /// （`com.apple.developer.usernotifications.filtering`）が要るので、Misskey は
  /// 対象外にした（#1411 の着手時の判断）。
  bool get supportsPushAlertFilter => false;

  /// Web Push サブスクリプションを解除する。
  ///
  /// [endpoint] Misskey の `/api/sw/unregister` は endpoint 必須のため呼び出し
  /// 側が保存済みの URL を渡す。Mastodon は `DELETE` エンドポイントが現在の
  /// OAuth トークンのサブスクリプションを対象とするため無視してよい。
  ///
  /// [p256dh] / [auth] は **Misskey 2026.10.0 以降で必須**（#1201）。⚠ 資格情報
  /// ではなく購読の auth secret (RFC 8291) で所有を確認する作りに変わったため、
  /// `endpoint` 単体では `INVALID_PARAM` の 400 になる。⚠⚠ **読めないことがある**
  /// —— v1.20 で keyset blob 化する前のインストールでは `PushKeyStore.read` が
  /// null を返すので、呼び出し側は null のまま渡してよい（その場合 2026.10.0 以降
  /// では解除できないが、endpoint だけ送る従来の挙動と同じで悪化はしない）。
  ///
  /// ⚠ **鍵は常に渡してよい。**2026.10.0 より前の `paramDef` は `endpoint` のみを
  /// 宣言しているが、`additionalProperties: false` を持たず、Misskey の Ajv も
  /// `removeAdditional` 無しで構成されているので、**余分なキーは無視される**
  /// （フォークの `endpoint-base.ts` で実測・2026-10-03）。版で分岐しない。
  Future<void> unsubscribePush({
    String? endpoint,
    String? p256dh,
    String? auth,
  });
}

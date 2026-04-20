/// Web Push サブスクリプションの登録・解除を行う Feature インターフェース。
///
/// Mastodon: POST /api/v1/push/subscription, DELETE /api/v1/push/subscription
/// Misskey: POST /api/sw/register, POST /api/sw/unregister
abstract mixin class PushSubscriptionSupport {
  /// サーバーの VAPID 公開鍵を取得する。
  ///
  /// Mastodon: GET /api/v1/instance → configuration.vapid.public_key
  ///           または GET /api/v2/instance → configuration.vapid.public_key
  /// Misskey: POST /api/meta → swPublickey
  Future<String?> getVapidPublicKey();

  /// Web Push サブスクリプションを登録する。
  ///
  /// [endpoint] リレーサーバーの受信 URL（例: `https://relay.capsicum.shrieker.net/push/<token>`）
  /// [p256dh] クライアント公開鍵（Base64URL エンコード）
  /// [auth] 認証シークレット（Base64URL エンコード）
  ///
  /// 戻り値: サーバーから返されたサブスクリプション情報（サーバー依存）。
  Future<Map<String, dynamic>> subscribePush({
    required String endpoint,
    required String p256dh,
    required String auth,
  });

  /// Web Push サブスクリプションを解除する。
  ///
  /// [endpoint] Misskey の `/api/sw/unregister` は endpoint 必須のため呼び出し
  /// 側が保存済みの URL を渡す。Mastodon は `DELETE` エンドポイントが現在の
  /// OAuth トークンのサブスクリプションを対象とするため無視してよい。
  Future<void> unsubscribePush({String? endpoint});
}

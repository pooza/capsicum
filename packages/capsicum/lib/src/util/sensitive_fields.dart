/// Sentry の request data から伏せるフィールド名の判定 (#499 / #1121)。
///
/// Mastodon の `subscribePush` は FormData を渡すため、キーが
/// `subscription[keys][p256dh]` のようにブラケット表記になる。Misskey は
/// JSON body（`i`）、relay は JSON body（`token`）。いずれも拾えるよう
/// 名前リストと末尾一致の二段構えにする。
///
/// ⚠⚠ **判定は「完全一致」か「`[名前]` / `.名前` の末尾一致」だけ。**
/// 部分一致ではないので、**`token` を載せても `entitlement_token` は拾えない**
/// （#1121 で実際に取りこぼしかけた）。⚠ **新しい機密フィールドを足すときは、
/// 既存の語に含まれるからと省略しないこと。**
///
/// ⚠ `main.dart` の `_scrubRequestData` から使う。**ここを private に戻さない**
/// —— main.dart の中に閉じていたときは**テストから触れず、載せ忘れても
/// 気付けなかった**。
library;

const _sensitiveFieldNames = [
  'i', // Misskey access token
  'access_token',
  'refresh_token',
  'token', // FCM / APNs device token in relay register
  'client_secret', // OAuth completeLogin の exchangeExtra (#528 manual fallback)
  'p256dh', // Web Push ECDH public key
  'auth', // Web Push auth secret
  'endpoint', // push_token が URL に埋め込まれた relay endpoint
  'publickey', // Misskey sw/register (VAPID / subscription 公開鍵)
  'privatekey', // 万一リクエストに載った場合の保険
  // ⚠ 有償リレーの利用権 (#597 / #1121)。それ自体が capability。
  // ⚠⚠ **`token` では拾えない**（上の「完全一致か末尾一致だけ」を参照）。
  'entitlement_token',
  // ⚠ ストアの購入を名指しできる（relay 側もログに出さない）。
  'purchase_id',
];

/// [key] を Sentry へ出す前に `[Filtered]` へ伏せるべきか。
bool isSensitiveFieldName(String key) {
  final lower = key.toLowerCase();
  // 完全一致または末尾一致（FormData の subscription[keys][p256dh] 等）
  return _sensitiveFieldNames.any(
    (n) => lower == n || lower.endsWith('[$n]') || lower.endsWith('.$n'),
  );
}

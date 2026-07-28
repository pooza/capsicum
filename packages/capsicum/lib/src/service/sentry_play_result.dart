import 'package:sentry_flutter/sentry_flutter.dart';

import '../ui/flash/flash_result_digest.dart';

/// 成功した Play 実行の「出目」を Sentry に記録する追跡ヘルパ (#898)。
///
/// 目的は #896 で確定した「同日でも絵文字インベントリの変化で出目が変わる」現象を、
/// **記憶に依らず客観検証する前向き実験**の材料を残すこと。「どの Play が・いつ・
/// どんなインベントリ版で・どんな出目だったか」の履歴が誰にも残っていないため、
/// 今後の実行を記録して予測（対象集合と交差する Play だけ変わる）と突き合わせる。
///
/// 設計:
/// - `captureMessage`（failure ではないので [reportOpFailure] の captureException
///   とは別経路）。level は info。
/// - fingerprint を固定して **1 issue に集約**し、Sentry UI 上で `flash.id` /
///   `emoji.hash` / `result.hash` タグで絞り込み・分布比較する（#875 と同じ思想）。
/// - **生の出目テキストは載せない**。スクリプトは `USER_NAME` 等を受け取れ、出目に
///   氏名が混じりうるため、比較には [playResultDigest] のハッシュだけを使う（PII を
///   中央に集めない）。絵文字の name/category はサーバー公開情報なので件数を載せる。
/// - Sentry SDK 側の失敗で Play の UI を止めない。
void reportPlayResult({
  required String flashId,
  required String host,
  required PlayEmojiInventoryDigest inventory,
  required String resultDigest,
}) {
  try {
    Sentry.captureMessage(
      'play.result',
      level: SentryLevel.info,
      withScope: (scope) {
        scope.setTag('flash.id', flashId);
        scope.setTag('host', host);
        scope.setTag('emoji.count', inventory.count.toString());
        scope.setTag('emoji.hash', inventory.hash);
        scope.setTag('result.hash', resultDigest);
        // カテゴリ別件数は事後の突き合わせ材料。タグにすると基数が爆発するので
        // context に構造化して載せる。
        scope.setContexts('play.emoji_categories', inventory.categoryCounts);
        scope.fingerprint = ['play.result'];
      },
    );
  } catch (_) {
    // 追跡記録の失敗で Play を巻き込まない。
  }
}

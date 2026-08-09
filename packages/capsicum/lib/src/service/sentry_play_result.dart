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
  required String settleBucket,
  bool forced = false,
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
        // ツリーが落ち着くまでどれだけ待ったか。アニメーションで出目を出す Play を
        // 途中経過のまま記録していないことを、突合の側から検算するための材料
        // （2026-08-10 の突合で判明した計測器の不備の再発検知）。生の ms は基数が
        // 増えるだけなのでバケットに丸める。
        scope.setTag('play.settle', settleBucket);
        // 「このまま実行する」(#881) は 0.16 評価器で 1.x スクリプトを走らせた
        // 結果で、評価器レジームが通常と異なる。#898 の突合で通常出目と混ざらない
        // よう分離する（fingerprint は据え置き・タグで切り分け）。
        scope.setTag('play.forced', forced.toString());
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

/// ツリーが落ち着かないまま上限に達した実行を記録する (#898)。
///
/// `Async:interval` で回り続ける Play は「確定した出目」を持たないため、
/// [reportPlayResult] を送らない（途中経過を指紋化した値が突合データに混ざると、
/// 2026-08-10 に判明したのと同じ「同日・同インベントリなのに出目が変わる」偽陽性を
/// 再生産する）。代わりに**そういう Play がどれだけあるか**だけをここで数える。
void reportPlayUnsettled({
  required String flashId,
  required String host,
  bool forced = false,
}) {
  try {
    Sentry.captureMessage(
      'play.unsettled',
      level: SentryLevel.info,
      withScope: (scope) {
        scope.setTag('flash.id', flashId);
        scope.setTag('host', host);
        scope.setTag('play.forced', forced.toString());
        scope.fingerprint = ['play.unsettled'];
      },
    );
  } catch (_) {
    // 追跡記録の失敗で Play を巻き込まない。
  }
}

/// #881 の degrade（新しい AiScript 宣言ゆえ評価せずブラウザ導線へ倒した）を
/// 観測する。失敗ではないので captureException ではなく info の captureMessage。
///
/// 「どの Play で・どれだけ degrade を踏むか」と、`isScriptLangUnsupported` の
/// 過剰発火（正当な Play の誤ブロック）を Sentry 上で測るための計装
/// （リリース前レビュー黄）。fingerprint 固定で 1 issue に集約し flash.id で絞る。
void reportPlayDegrade({required String flashId, String? host}) {
  try {
    Sentry.captureMessage(
      'play.degrade',
      level: SentryLevel.info,
      withScope: (scope) {
        scope.setTag('flash.id', flashId);
        scope.setTag('host', host ?? '-');
        scope.fingerprint = ['play.degrade'];
      },
    );
  } catch (_) {
    // 計装の失敗で degrade 表示を止めない。
  }
}

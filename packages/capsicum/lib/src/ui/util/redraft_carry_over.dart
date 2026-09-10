import 'package:capsicum_core/capsicum_core.dart';

/// 「削除して再編集」で何を引き継ぐかの**宣言** (#1113)。
///
/// ## ⚠⚠ なぜ表にしたか
///
/// **同じ形の取りこぼしが 4 回続いた** — [#703](https://github.com/pooza/capsicum/issues/703)
/// （CW / 添付 / 閲覧注意）→ [#756](https://github.com/pooza/capsicum/issues/756)（引用）
/// → [#384](https://github.com/pooza/capsicum/issues/384)（チャンネル）
/// → #1113（返信先 / ローカルのみ / 言語）。⚠ **そのたびに 1 項目ずつ足してきた
/// ので、次に `PostDraft` へ項目が増えたらまた漏れる。**
///
/// [redraftCarryOverPolicy] は **`PostDraft` の全項目**について態度を宣言する。
/// 宣言の無い項目が増えると `redraft_carry_over_test` が落ちるので、**増やした
/// 人が必ず考える**ことになる。
///
/// ## ⚠ 判断の軸は「ユーザーに見えるか」
///
/// WebUI（Mastodon の `REDRAFT` reducer / Misskey の `initialNote`）を既定の
/// 参照点にしたうえで、**引き継ぐ理由は 2 種類ある**:
///
/// | | 例 | 引き継ぐ理由 |
/// | --- | --- | --- |
/// | **見えない状態** | `localOnly` / `inReplyToId` / `language` / `quoteApprovalPolicy` | ⚠⚠ **安全**。引き継がないと**無言で**公開範囲や文脈が変わる |
/// | **見える状態** | 本文 / CW / 投票の選択肢 | **便利**。齟齬が出ても画面に出ているので直せる |
///
/// ⚠ **`localOnly` を落とすのがいちばん重い。**「ローカルのみ」で投稿したものを
/// 再編集すると旗が外れて連合へ流れるのに、`scope` は引き継がれるので**画面上は
/// 何も変わったように見えない**。気づく手掛かりが無い。
enum RedraftCarryOver {
  /// 元投稿から引き継ぐ。
  carry,

  /// **意図的に**引き継がない。⚠ **理由を [redraftCarryOverReasons] に書くこと。**
  drop,

  /// `Post` 側に対応する値が無いので引き継げない（compose 固有の入力等）。
  notInPost,
}

/// `PostDraft` の全項目に対する態度。
///
/// ⚠ **項目を増やしたらここにも足す。**足さないと検査が落ちる。
const redraftCarryOverPolicy = <String, RedraftCarryOver>{
  'content': RedraftCarryOver.carry,
  'scope': RedraftCarryOver.carry,
  'inReplyToId': RedraftCarryOver.carry,
  'quoteId': RedraftCarryOver.carry,
  'mediaIds': RedraftCarryOver.carry,
  'spoilerText': RedraftCarryOver.carry,
  'sensitive': RedraftCarryOver.carry,
  'localOnly': RedraftCarryOver.carry,
  'channelId': RedraftCarryOver.carry,
  'language': RedraftCarryOver.carry,
  'pollOptions': RedraftCarryOver.carry,
  'pollExpiresIn': RedraftCarryOver.carry,
  'pollMultiple': RedraftCarryOver.carry,
  'pollHideTotals': RedraftCarryOver.notInPost,
  'skipMulukhiya': RedraftCarryOver.notInPost,
  'scheduledAt': RedraftCarryOver.drop,
  'quoteApprovalPolicy': RedraftCarryOver.carry,
};

/// `carry` 以外を選んだ理由。⚠ **理由の無い `drop` は検査で落とす。**
const redraftCarryOverReasons = <String, String>{
  'pollHideTotals': 'Post.poll に「途中経過を隠す」が無い（Misskey の投稿には載らない）',
  'skipMulukhiya': 'モロヘイヤを通すかは送信時の選択で、投稿には残らない',
  'scheduledAt':
      '予約投稿の時刻は引き継がない。⚠ 元の時刻は既に過去なので、'
      'そのまま渡すと送信が失敗する。再設定させるのが正しい',
};

/// 投票の期限（秒）を、元投稿の `expiresAt` から作り直す (#1113)。
///
/// ⚠⚠ **`expiresAt` をそのまま渡せない。**`PostDraft` が要求するのは**残り秒数**
/// で、元投稿の期限は**既に過去**か、過去でなくとも「投稿し直した時点からの
/// 残り」とは違う。Mastodon の WebUI が `expiresInFromExpiresAt` で変換して
/// いるのと同じ理由。
///
/// ⚠ **期限切れ / 不明なら [fallback] へ落とす**（2026-09-10 pooza 判断）。
/// 再投稿は新しい投票なので、既定の期限から始めるのが自然。
///
/// 戻り値は [allowed] のうち**残り時間以上で最も近いもの**。⚠ **短い側へ丸めない**
/// —— 5 分残っている投票を 5 分の選択肢へ落とすと、**送信までの操作時間で
/// 期限切れになりうる**。
int redraftPollExpiresIn({
  required DateTime? expiresAt,
  required DateTime now,
  required Iterable<int> allowed,
  required int fallback,
}) {
  if (expiresAt == null) return fallback;
  final remaining = expiresAt.difference(now).inSeconds;
  if (remaining <= 0) return fallback;
  final sorted = allowed.toList()..sort();
  for (final candidate in sorted) {
    if (candidate >= remaining) return candidate;
  }
  // 残りが最長の選択肢より長い（サーバー側の上限が違う等）。最長へ寄せる。
  return sorted.isEmpty ? fallback : sorted.last;
}

/// 返信先を解決する (#1113)。
///
/// ⚠ **`replyTo` が優先。**返信として開いた compose に redraft を重ねる経路は
/// 無いが、両方来たときに「今回の操作」を勝たせるのが自然。
///
/// ⚠ **redraft は `Post` ではなく id しか持たない。**元投稿の `inReplyToId` は
/// 「その投稿が誰への返信だったか」なので、そのまま次の投稿の返信先になる。
String? resolveComposeInReplyToId(Post? replyTo, Post? redraft) =>
    replyTo?.id ?? redraft?.inReplyToId;

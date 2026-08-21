/// 投稿済みメディアの説明（ALT）を編集する導線を出してよいか (#121)。
///
/// ⚠ **間違えると投稿が壊れる判定なので、画面から切り出してテストで固定する。**
/// Mastodon には投稿済み添付の説明だけを変える API が無く、投稿の更新 API を
/// 使うしかない。その API は「送らなかったパラメータ」を現状維持ではなく
/// **空で更新**として扱うため、モロヘイヤの補完なしに呼ぶと **添付が全部外れ、
/// CW と閲覧注意も消える**（mulukhiya#4589）。
///
/// 引数を bool で受けるのは、画面全体を pump せずに出し分けを試験するため
/// （`desktop_menu_model.dart` の「画面メニュー貢献のテストの流儀」#960 と同じ）。
///
/// - [supportsMediaUpdate] … アダプタが `MediaUpdateSupport` を持つか
/// - [needsMulukhiya] … その API がモロヘイヤの補完を前提にするか（Mastodon は
///   true、Misskey は `drive/files/update` が投稿済みでも効くので false）
/// - [hasMulukhiya] … 現在のアカウントのサーバーにモロヘイヤがいるか
/// - [isOwnPost] … 自分の投稿か（他人の添付は編集できない）
/// - [hasPostContext] … 投稿 id と投稿者 id が揃っているか。メディアビューアは
///   投稿を伴わない経路からも開くため、揃わないことがある
bool canEditAttachmentDescription({
  required bool supportsMediaUpdate,
  required bool needsMulukhiya,
  required bool hasMulukhiya,
  required bool isOwnPost,
  required bool hasPostContext,
}) {
  if (!hasPostContext) return false;
  if (!supportsMediaUpdate) return false;
  if (needsMulukhiya && !hasMulukhiya) return false;
  return isOwnPost;
}

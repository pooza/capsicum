import '../../service/server_version_checker.dart';

/// ALT 編集の PUT を安全に受けられる最小のモロヘイヤ版 (#999)。
///
/// これ未満のモロヘイヤは `X-Mulukhiya-Purpose: media_update` を**受理はする**が、
/// 上流へ送る body が `{status, media_attributes}` だけで `media_ids` /
/// `spoiler_text` / `sensitive` を補完しない（5.33.0 の `mastodon_controller.rb`）。
/// nginx の `$status_put_backend` map は 5.33.0 にもあるので **405 では止まらず、
/// 投稿から添付が全部外れ CW と閲覧注意も消える**。補完が入るのは 5.34.0 から。
const kMulukhiyaMediaUpdateMinVersion = '5.34.0';

/// モロヘイヤの版が ALT 編集の補完を持つか (#999)。[version] が null（モロヘイヤ
/// 不在・版が読めない）なら false に倒す。**判定を誤ると投稿が壊れる側なので、
/// 「分からない」は常に「出さない」に寄せる。**
bool mulukhiyaSupportsMediaUpdate(String? version) {
  if (version == null || version.isEmpty) return false;

  return ServerVersionChecker.isAtLeast(
    version,
    kMulukhiyaMediaUpdateMinVersion,
  );
}

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
/// - [mulukhiyaHandlesMediaUpdate] … そのモロヘイヤが**補完を持つ版**か
///   （5.34.0 以降。[mulukhiyaSupportsMediaUpdate] で判定する・#999）
/// - [isOwnPost] … 自分の投稿か（他人の添付は編集できない）
/// - [hasPostContext] … 投稿 id と投稿者 id が揃っているか。メディアビューアは
///   投稿を伴わない経路からも開くため、揃わないことがある
bool canEditAttachmentDescription({
  required bool supportsMediaUpdate,
  required bool needsMulukhiya,
  required bool hasMulukhiya,
  required bool mulukhiyaHandlesMediaUpdate,
  required bool isOwnPost,
  required bool hasPostContext,
}) {
  if (!hasPostContext) return false;
  if (!supportsMediaUpdate) return false;
  // ⚠ **有無だけでなく版も見る (#999)。**有無しか見ていなかったため、補完の無い
  // 5.33.0 のサーバーでも導線が出ていた（自前 4 サーバーが全部これだった）。
  final mulukhiyaReady = hasMulukhiya && mulukhiyaHandlesMediaUpdate;
  if (needsMulukhiya && !mulukhiyaReady) return false;
  return isOwnPost;
}

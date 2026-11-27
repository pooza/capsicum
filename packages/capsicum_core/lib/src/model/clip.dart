class NoteClip {
  final String id;
  final String name;
  final String? description;

  /// 公開のクリップか (#1050)。Misskey の `isPublic`。
  final bool isPublic;

  /// 作った人の id (#1050)。`notes/clips`（ほかの人の公開クリップも返る）から
  /// 自分のものを選ぶのに使う。読めなければ null。
  final String? userId;

  /// 作った人の表示名 (#1377)。お気に入りのクリップの一覧で、誰のクリップかを
  /// 出すのに使う。読めなければ null。
  final String? ownerName;

  /// 自分がお気に入りに入れているか (#1377)。Misskey は認証付きで引いたときだけ
  /// 返す。分からなければ null（「入れていない」とは読まない）。
  final bool? isFavorited;

  const NoteClip({
    required this.id,
    required this.name,
    this.description,
    this.isPublic = false,
    this.userId,
    this.ownerName,
    this.isFavorited,
  });
}

/// クリップを作る・変えるときの中身 (#1050)。Misskey の `clips/create` /
/// `clips/update` の引数そのまま。
class ClipDraft {
  /// 1〜100 文字。
  final String name;

  /// 〜2048 文字。null / 空で「説明なし」。
  final String? description;
  final bool isPublic;

  const ClipDraft({
    required this.name,
    this.description,
    this.isPublic = false,
  });
}

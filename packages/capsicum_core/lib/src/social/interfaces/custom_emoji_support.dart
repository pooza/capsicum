class CustomEmoji {
  final String shortcode;
  final String url;
  final String? category;
  final List<String> aliases;

  /// Mastodon の `visible_in_picker`。`false` の絵文字は emoji picker UI には
  /// 出さないが、shortcode を直接書けば投稿には使えるサーバー設定。
  /// `getEmojis()` は picker / 警告判定 / プレビュー / 探索を兼ねるため全件返し、
  /// picker 側でフィルタする (#622)。Misskey 等この概念が無いバックエンドは
  /// default true のまま。**フィルタの入口は [CustomEmojiInputVisibility.offeredForInput]**
  /// で、このフラグ単体を直接見ないこと（#944 のカテゴリ条件を取りこぼす）。
  final bool visibleInPicker;

  /// Mastodon 4.6 の `featured`。カテゴリごとの代表（フィーチャー指定）絵文字を
  /// 表す。picker で「フィーチャー」セクションに優先表示する (#735)。未対応
  /// サーバーや featured 未指定の絵文字は false。
  final bool featured;

  const CustomEmoji({
    required this.shortcode,
    required this.url,
    this.category,
    this.aliases = const [],
    this.visibleInPicker = true,
    this.featured = false,
  });
}

/// カテゴリ名がこの語を含むグループは、**新規入力の導線から外す** (#944)。
///
/// 旧ショートコードを「旧コードのため非推奨」等のカテゴリへ退避する運用に対応する。
/// 既存投稿のレンダリングのために絵文字自体はサーバーに残す必要があるが、これから
/// 打つ人には出したくない、という要求。
///
/// **部分一致にするのは、サーバー間でカテゴリ名の表記が揺れているため**
/// （デルムリン丼「旧コードのため非推奨」/ キュアスタ！「旧コードの為非推奨」）。
/// 完全一致にすると片方を取りこぼすうえ、サーバー側の改名のたびにアプリの
/// リリースが必要になる。**サーバー名で分岐していない**ので、特定サーバー向けの
/// 個別対応にはならない（この語をカテゴリ名に使えばどのサーバーでも同じに効く）。
const kDeprecatedEmojiCategoryMarker = '非推奨';

extension CustomEmojiInputVisibility on CustomEmoji {
  /// 新規入力の導線（ピッカー本体 / カスタムタブの検索 / `:` ショートコード補完）
  /// に出してよい絵文字か (#622 / #944)。
  ///
  /// **`getEmojis()` の戻り値をそのまま絞るのに使わないこと。** あちらは
  /// #609 の未登録ショートコード警告の母集合を兼ねており、ここで絞ると旧コードを
  /// 手打ちしたときに「未登録」の赤波線が誤爆する。塞ぐのは入力補助の導線だけで、
  /// ショートコードを直接書けば従来どおり投稿できる。
  bool get offeredForInput =>
      visibleInPicker &&
      !(category?.contains(kDeprecatedEmojiCategoryMarker) ?? false);
}

abstract mixin class CustomEmojiSupport {
  Future<List<CustomEmoji>> getEmojis();

  /// Returns the user's pinned emoji palette (e.g. from Misskey's registry).
  /// Adapters that don't support palettes return an empty list by default.
  Future<List<String>> getEmojiPalette() async => const [];
}

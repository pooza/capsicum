class CustomEmoji {
  final String shortcode;
  final String url;
  final String? category;
  final List<String> aliases;

  /// Mastodon の `visible_in_picker`。`false` の絵文字は emoji picker UI には
  /// 出さないが、shortcode を直接書けば投稿には使えるサーバー設定。
  /// `getEmojis()` は picker / 警告判定 / プレビュー / 探索を兼ねるため全件返し、
  /// picker 側で `visibleInPicker` を見てフィルタする (#622)。Misskey 等この概念が
  /// 無いバックエンドは default true のまま。
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

abstract mixin class CustomEmojiSupport {
  Future<List<CustomEmoji>> getEmojis();

  /// Returns the user's pinned emoji palette (e.g. from Misskey's registry).
  /// Adapters that don't support palettes return an empty list by default.
  Future<List<String>> getEmojiPalette() async => const [];
}

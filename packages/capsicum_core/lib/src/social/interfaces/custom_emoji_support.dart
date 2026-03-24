class CustomEmoji {
  final String shortcode;
  final String url;
  final String? category;
  final List<String> aliases;

  const CustomEmoji({
    required this.shortcode,
    required this.url,
    this.category,
    this.aliases = const [],
  });
}

abstract mixin class CustomEmojiSupport {
  Future<List<CustomEmoji>> getEmojis();

  /// Returns the user's pinned emoji palette (e.g. from Misskey's registry).
  /// Adapters that don't support palettes return an empty list by default.
  Future<List<String>> getEmojiPalette() async => const [];
}

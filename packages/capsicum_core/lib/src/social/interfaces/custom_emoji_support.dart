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
}

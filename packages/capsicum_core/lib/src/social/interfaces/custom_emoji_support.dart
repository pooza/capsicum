class CustomEmoji {
  final String shortcode;
  final String url;
  final String? category;

  const CustomEmoji({
    required this.shortcode,
    required this.url,
    this.category,
  });
}

abstract mixin class CustomEmojiSupport {
  Future<List<CustomEmoji>> getEmojis();
}

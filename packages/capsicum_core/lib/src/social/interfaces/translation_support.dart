abstract mixin class TranslationSupport {
  Future<TranslationResult> translatePost(String postId, {String? targetLang});
}

class TranslationResult {
  final String content;
  final String? detectedLanguage;
  final String? provider;

  const TranslationResult({
    required this.content,
    this.detectedLanguage,
    this.provider,
  });
}

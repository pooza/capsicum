class PreviewCard {
  final String url;
  final String title;
  final String? description;
  final String? imageUrl;

  const PreviewCard({
    required this.url,
    required this.title,
    this.description,
    this.imageUrl,
  });
}

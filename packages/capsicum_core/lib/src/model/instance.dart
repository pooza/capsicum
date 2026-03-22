class Instance {
  final String name;
  final String? description;
  final String? iconUrl;
  final String? version;
  final String? themeColor;
  final int? userCount;
  final int? postCount;

  const Instance({
    required this.name,
    this.description,
    this.iconUrl,
    this.version,
    this.themeColor,
    this.userCount,
    this.postCount,
  });
}

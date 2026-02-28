class Instance {
  final String name;
  final String? description;
  final String? iconUrl;
  final String? version;
  final int? userCount;
  final int? postCount;

  const Instance({
    required this.name,
    this.description,
    this.iconUrl,
    this.version,
    this.userCount,
    this.postCount,
  });
}

class Flash {
  final String id;
  final String title;
  final String? summary;
  final String? userName;

  const Flash({
    required this.id,
    required this.title,
    this.summary,
    this.userName,
  });
}

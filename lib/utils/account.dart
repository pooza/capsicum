class Account {
  Map<String, dynamic> params = {};

  Account({
    required this.params,
  });

  String get name => params['name'] ?? '';
}

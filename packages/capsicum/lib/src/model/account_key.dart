import 'package:capsicum_backends/capsicum_backends.dart';

/// Uniquely identifies an account: (backendType, host, username).
class AccountKey {
  final BackendType type;
  final String host;
  final String username;

  const AccountKey({
    required this.type,
    required this.host,
    required this.username,
  });

  String toStorageKey() => '${type.name}://$username@$host';

  factory AccountKey.fromStorageKey(String key) {
    final uri = Uri.parse(key);
    return AccountKey(
      type: BackendType.values.firstWhere((t) => t.name == uri.scheme),
      host: uri.host,
      username: uri.userInfo,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AccountKey &&
      type == other.type &&
      host == other.host &&
      username == other.username;

  @override
  int get hashCode => Object.hash(type, host, username);
}

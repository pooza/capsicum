import 'package:capsicum_core/capsicum_core.dart';

import 'account_key.dart';

/// Represents a logged-in account with its adapter and credentials.
class Account {
  final AccountKey key;
  final DecentralizedBackendAdapter adapter;
  final User user;
  final UserSecret userSecret;
  final ClientSecretData? clientSecret;

  const Account({
    required this.key,
    required this.adapter,
    required this.user,
    required this.userSecret,
    this.clientSecret,
  });
}

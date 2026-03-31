import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';

import 'account_key.dart';

/// Represents a logged-in account with its adapter and credentials.
class Account {
  final AccountKey key;
  final DecentralizedBackendAdapter adapter;
  final User user;
  final UserSecret userSecret;
  final ClientSecretData? clientSecret;
  final MulukhiyaService? mulukhiya;
  final String? softwareVersion;

  const Account({
    required this.key,
    required this.adapter,
    required this.user,
    required this.userSecret,
    this.clientSecret,
    this.mulukhiya,
    this.softwareVersion,
  });

  Account copyWithUser(User user) => Account(
    key: key,
    adapter: adapter,
    user: user,
    userSecret: userSecret,
    clientSecret: clientSecret,
    mulukhiya: mulukhiya,
    softwareVersion: softwareVersion,
  );

  Account copyWithMulukhiya(MulukhiyaService? mulukhiya) => Account(
    key: key,
    adapter: adapter,
    user: user,
    userSecret: userSecret,
    clientSecret: clientSecret,
    mulukhiya: mulukhiya,
    softwareVersion: softwareVersion,
  );
}

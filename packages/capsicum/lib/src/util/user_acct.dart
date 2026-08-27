import 'package:capsicum_core/capsicum_core.dart';

/// Builds the `user@host` acct string for [user].
///
/// Local users (no host, or empty host) collapse to the bare username so the
/// result is usable both for display and for inserting a `@acct` mention. This
/// is the single source of truth for acct construction; UI that needs to copy
/// a handle or open a mention compose should go through here rather than
/// re-deriving `username`/`host` (the latter scatters the null/empty-host
/// guard and drifts).
String userAcct(User user) {
  final host = user.host;
  if (host != null && host.isNotEmpty) {
    return '${user.username}@$host';
  }
  return user.username;
}

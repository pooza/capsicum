import 'package:capsicum_core/capsicum_core.dart';

/// Builds the `user@host` acct string for [user].
///
/// Local users (no host, or empty host) collapse to the bare username so the
/// result is usable both for display and for inserting a `@acct` mention. This
/// is the single source of truth for acct construction; UI that needs to copy
/// a handle or open a mention compose should go through here rather than
/// re-deriving `username`/`host` (the latter scatters the null/empty-host
/// guard and drifts).
///
/// [localHost] を渡すと、**自サーバーと同じ host もローカル扱い**にする (#1166)。
/// ローカルユーザーの `User.host` に自サーバーの host が入っている backend があり、
/// そのまま組むと `user@自サーバー` になって、Mastodon の `mentions`（ローカルは
/// `user`）との重複判定がずれる。返信の宛先のように**自サーバーから見た形**が
/// 要る場面で渡す。
String userAcct(User user, {String? localHost}) =>
    acctOf(user.username, user.host, localHost: localHost);

/// [userAcct] の中身。[User] を持たない場面（本文から抜いたメンション等）用。
///
/// ⚠ host の比較は大文字小文字を区別しない。
String acctOf(String username, String? host, {String? localHost}) {
  if (host == null || host.isEmpty) return username;
  if (localHost != null && host.toLowerCase() == localHost.toLowerCase()) {
    return username;
  }
  return '$username@$host';
}

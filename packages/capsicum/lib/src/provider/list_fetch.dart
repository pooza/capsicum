import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../service/sentry_op_failure.dart';
import '../util/oauth_scope_error.dart';
import 'account_manager_provider.dart';

/// 一覧の取得の失敗を観測へ流してから、そのまま画面へ返す (#1361)。
///
/// Play の一覧と チャンネルの一覧で同じ形が 2 本あったのを寄せた。
///
/// ⚠ 権限の足りない古いトークンの失敗（[isOAuthScopeError]）は送らない。
/// 再ログインで直る既知の条件で、画面は [oauthScopeErrorMessage] を出す。
Future<T> fetchListReportingFailure<T>(
  Ref ref, {
  required String tagKey,
  required String operation,
  required Future<T> Function() fetch,
}) async {
  // ⚠ 通信の前に取る。通信の間に provider が破棄されると `ref` を読めない。
  final account = ref.read(currentAccountProvider);
  try {
    return await fetch();
  } catch (e, st) {
    if (!isOAuthScopeError(e)) {
      reportOpFailure(
        tagKey: tagKey,
        operation: operation,
        error: e,
        stackTrace: st,
        account: account,
      );
    }
    rethrow;
  }
}

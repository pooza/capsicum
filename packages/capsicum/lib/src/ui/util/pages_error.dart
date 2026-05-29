import '../../model/account.dart';
import '../../service/sentry_op_failure.dart';

/// Misskey Pages 読み取り操作失敗時に Sentry へ詳細を流す共通フック (#625)。
/// 共通ヘルパ [reportOpFailure] に委譲し、`pages.op` tag + host/backend tag +
/// scrubException を一括適用する。
void reportPagesOpFailure(
  String operation,
  Object error,
  StackTrace st, {
  Account? account,
}) {
  reportOpFailure(
    tagKey: 'pages.op',
    operation: operation,
    error: error,
    stackTrace: st,
    account: account,
  );
}

import '../../model/account.dart';
import '../../service/sentry_op_failure.dart';

/// drive 操作失敗時に Sentry へ詳細を流す共通フック (#460)。共通ヘルパ
/// [reportOpFailure] に委譲し、`drive.op` tag + host/backend tag +
/// scrubException を一括適用する (#625)。
void reportDriveOpFailure(
  String operation,
  Object error,
  StackTrace st, {
  Account? account,
}) {
  reportOpFailure(
    tagKey: 'drive.op',
    operation: operation,
    error: error,
    stackTrace: st,
    account: account,
  );
}

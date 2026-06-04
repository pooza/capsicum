import '../../model/account.dart';
import '../../service/sentry_op_failure.dart';

/// chat 操作失敗時に Sentry へ詳細を流す共通フック (#460 の drive 版と同型)。
/// 共通ヘルパ [reportOpFailure] に委譲し、`chat.op` tag + host/backend tag +
/// scrubException を一括適用する (#625)。
void reportChatOpFailure(
  String operation,
  Object error,
  StackTrace st, {
  Account? account,
}) {
  reportOpFailure(
    tagKey: 'chat.op',
    operation: operation,
    error: error,
    stackTrace: st,
    account: account,
  );
}

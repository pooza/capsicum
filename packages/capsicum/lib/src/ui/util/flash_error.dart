import '../../model/account.dart';
import '../../service/sentry_op_failure.dart';

/// Misskey Flash（UI 表記は Play）操作失敗時に Sentry へ詳細を流す共通フック
/// (#830)。Pages の [reportPagesOpFailure] と同型で、`flash.op` tag +
/// host/backend tag + scrubException を一括適用する。
///
/// Misskey の URL には `?i=<accessToken>` が載るため、DioException を素で
/// captureException してはいけない（#460 と同型の漏洩になる）。
void reportFlashOpFailure(
  String operation,
  Object error,
  StackTrace st, {
  Account? account,
}) {
  reportOpFailure(
    tagKey: 'flash.op',
    operation: operation,
    error: error,
    stackTrace: st,
    account: account,
  );
}

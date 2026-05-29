import 'package:dio/dio.dart';

import '../../model/account.dart';
import '../../service/sentry_op_failure.dart';

/// drive 操作系 SnackBar に流す短い人間向け要約。DioException の URL や
/// ヘッダ等の機微情報を流さず、status code / type だけ含める (#460)。
String summarizeDriveError(Object error) {
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status != null) return 'サーバーエラー (HTTP $status)';
    return 'ネットワークエラー (${error.type.name})';
  }
  return 'エラーが発生しました';
}

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

import 'package:dio/dio.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// chat 操作系 SnackBar / エラーパネルに流す短い人間向け要約。
/// DioException の URL / ヘッダ / Authorization / push_token 等の機微情報を
/// 流さず、status code / type だけ含める (#460 の drive 版と同型)。
String summarizeChatError(Object error) {
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status != null) return 'サーバーエラー (HTTP $status)';
    return 'ネットワークエラー (${error.type.name})';
  }
  return 'エラーが発生しました';
}

/// chat 操作失敗時に Sentry へ詳細を流す共通フック (#460 の drive 版と同型)。
/// 失敗しても UI 更新を止めないよう内側で try/catch する。
void reportChatOpFailure(String operation, Object error, StackTrace st) {
  try {
    Sentry.captureException(
      error,
      stackTrace: st,
      withScope: (scope) {
        scope.setTag('chat.op', operation);
        scope.fingerprint = [
          'chat.op',
          operation,
          error.runtimeType.toString(),
        ];
      },
    );
  } catch (_) {
    // Sentry 失敗で UI 更新を止めない。
  }
}

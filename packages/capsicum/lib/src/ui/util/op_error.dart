import 'package:dio/dio.dart';

/// chat / drive など op 系の SnackBar・エラーパネルに流す短い人間向け要約。
///
/// DioException の URL / ヘッダ / Authorization / push_token 等の機微情報を
/// 流さず、status code / type だけ含める。chat_error / drive_error に
/// バイト単位で同一の実装が重複していたものを集約した（#460 / #650）。
String summarizeOpError(Object error) {
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status != null) return 'サーバーエラー (HTTP $status)';
    return 'ネットワークエラー (${error.type.name})';
  }
  return 'エラーが発生しました';
}

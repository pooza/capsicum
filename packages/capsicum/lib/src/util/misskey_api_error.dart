import 'package:dio/dio.dart';

/// Misskey API のエラーレスポンス（`{ "error": { "code": ..., ... } }`）から
/// `error.code` を取り出す。
///
/// Misskey は失敗を HTTP ステータス + ボディの `error.code`（`ALREADY_LIKED` /
/// `YOUR_FLASH` 等）で返す。DioException 以外・想定外の形状では null を返す。
/// 呼び出し側は code で分岐して「非べき等な結果コードは成功として吸収する」
/// （#873）等の判断に使う。
String? misskeyApiErrorCode(Object error) {
  if (error is! DioException) return null;
  final data = error.response?.data;
  if (data is! Map) return null;
  final inner = data['error'];
  if (inner is! Map) return null;
  final code = inner['code'];
  return code is String ? code : null;
}

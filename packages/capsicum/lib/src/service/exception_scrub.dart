import 'package:dio/dio.dart';

/// DioException や OAuth 例外のメタ情報のみを抜き出した安全な例外に詰め替える。
///
/// Dio はバージョンによって `requestOptions.uri` を `message` や `toString()` に
/// 埋め込むケースがあり、URL には relay の `push_token` や Mastodon
/// `client_secret` クエリが含まれることがある。Sentry / debugPrint / ログ
/// ファイルに流す前に必ずこのユーティリティを通す。
///
/// `service.push_registration` の relay 経路、`ui.login_screen` の OAuth
/// fallback 経路で共通利用 (#499)。
Object scrubException(Object e) {
  if (e is DioException) {
    final path = e.requestOptions.path.split('?').first;
    return StateError(
      'DioException ${e.type.name} '
      'status=${e.response?.statusCode ?? '-'} '
      'path=$path',
    );
  }
  return e;
}

import 'package:dio/dio.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

/// DioException や OAuth 例外のメタ情報のみを抜き出した安全な例外に詰め替える。
///
/// Dio はバージョンによって `requestOptions.uri` を `message` や `toString()` に
/// 埋め込むケースがあり、URL には relay の `push_token` や Mastodon
/// `client_secret` クエリが含まれることがある。Sentry / debugPrint / ログ
/// ファイルに流す前に必ずこのユーティリティを通す。
///
/// `service.push_registration` の relay 経路、`ui.login_screen` の OAuth
/// fallback 経路、`provider.chat_provider` の WebSocket 接続例外 (#552) で
/// 共通利用 (#499)。
///
/// DioException 以外でも、`WebSocketChannelException` / `SocketException`
/// 等が `toString()` に `wss://host/streaming?i=<accessToken>` のような
/// 機密クエリ付き URL を含めることがあるため、文字列表現から既知の機密
/// クエリパラメータ (`i` / `token` / `access_token` / `push_token` /
/// `client_secret`) の値をマスクして詰め替える。
Object scrubException(Object e) {
  if (e is DioException) {
    final path = e.requestOptions.path.split('?').first;
    return StateError(
      'DioException ${e.type.name} '
      'status=${e.response?.statusCode ?? '-'} '
      'path=$path',
    );
  }
  if (e is IAPError) {
    // IAPError.details はプラットフォーム例外の内部情報（StoreKit /
    // Play Billing の PlatformException details 等）を含みうるため、
    // 識別子の source / code のみに詰め替える (#428)。
    return StateError('IAPError source=${e.source} code=${e.code}');
  }
  if (e is FormatException) {
    // FormatException.toString() は source（パース対象の生データ断片）を
    // 含む。streaming のフレーム parse 失敗時に投稿本文の断片が混入する
    // ため、message のみ残して source / offset は落とす (#586)。
    return StateError('FormatException: ${e.message}');
  }
  final text = e.toString();
  if (_sensitiveQueryParam.hasMatch(text)) {
    return StateError(
      '${e.runtimeType}: '
      '${text.replaceAllMapped(_sensitiveQueryParam, (m) => '${m[1]}***')}',
    );
  }
  return e;
}

final _sensitiveQueryParam = RegExp(
  r'''([?&](?:i|token|access_token|push_token|client_secret)=)[^&\s'"]+''',
  caseSensitive: false,
);

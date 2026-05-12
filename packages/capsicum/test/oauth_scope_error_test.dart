import 'package:capsicum/src/util/oauth_scope_error.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

DioException _fakeDioException({
  required int statusCode,
  Object? body,
  Map<String, List<String>>? headers,
}) {
  final requestOptions = RequestOptions(path: '/api/v1/conversations');
  return DioException(
    requestOptions: requestOptions,
    response: Response<dynamic>(
      requestOptions: requestOptions,
      statusCode: statusCode,
      data: body,
      headers: Headers.fromMap(headers ?? {}),
    ),
    type: DioExceptionType.badResponse,
  );
}

void main() {
  group('isOAuthScopeError (#441)', () {
    test('non-DioException は false', () {
      expect(isOAuthScopeError(Exception('boom')), isFalse);
    });

    test('Mastodon 401 + body.error=insufficient_scope は true', () {
      expect(
        isOAuthScopeError(
          _fakeDioException(
            statusCode: 401,
            body: {'error': 'insufficient_scope'},
          ),
        ),
        isTrue,
      );
    });

    test('Mastodon 401 + WWW-Authenticate に insufficient_scope は true', () {
      expect(
        isOAuthScopeError(
          _fakeDioException(
            statusCode: 401,
            headers: {
              'www-authenticate': [
                'Bearer realm="example", error="insufficient_scope"',
              ],
            },
          ),
        ),
        isTrue,
      );
    });

    test('Misskey 403 + error.code=PERMISSION_DENIED は true', () {
      expect(
        isOAuthScopeError(
          _fakeDioException(
            statusCode: 403,
            body: {
              'error': {
                'code': 'PERMISSION_DENIED',
                'message': 'You do not have permission',
              },
            },
          ),
        ),
        isTrue,
      );
    });

    test('Misskey 403 + error.code=NO_AUTH_SCOPE は true', () {
      expect(
        isOAuthScopeError(
          _fakeDioException(
            statusCode: 403,
            body: {
              'error': {'code': 'NO_AUTH_SCOPE'},
            },
          ),
        ),
        isTrue,
      );
    });

    test('Mastodon 401 + 別 error 値 (invalid_token) は false', () {
      expect(
        isOAuthScopeError(
          _fakeDioException(statusCode: 401, body: {'error': 'invalid_token'}),
        ),
        isFalse,
      );
    });

    test('Misskey 403 + 別 code (BLOCKED) は false', () {
      expect(
        isOAuthScopeError(
          _fakeDioException(
            statusCode: 403,
            body: {
              'error': {'code': 'BLOCKED'},
            },
          ),
        ),
        isFalse,
      );
    });

    test('500 等の他ステータスは false', () {
      expect(
        isOAuthScopeError(
          _fakeDioException(statusCode: 500, body: {'error': 'oops'}),
        ),
        isFalse,
      );
    });

    test('Response 自体が無い (network error) は false', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/api/v1/conversations'),
        type: DioExceptionType.connectionError,
      );
      expect(isOAuthScopeError(e), isFalse);
    });
  });
}

import 'package:capsicum/src/util/exception_scrub.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('scrubException', () {
    test('MiAuth の session UUID をパスからマスクする (#790)', () {
      final e = DioException(
        requestOptions: RequestOptions(
          path: '/api/miauth/3f2a1b9c-dead-beef/check',
        ),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/'),
          statusCode: 400,
        ),
      );

      final scrubbed = scrubException(e).toString();
      expect(scrubbed, contains('/api/miauth/***/check'));
      expect(scrubbed, isNot(contains('3f2a1b9c-dead-beef')));
    });

    test('機密でないパスはそのまま残す', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/api/v1/timelines/home'),
        type: DioExceptionType.connectionError,
      );

      expect(scrubException(e).toString(), contains('/api/v1/timelines/home'));
    });

    test('URL の機密クエリ値をマスクする', () {
      final e = StateError(
        'WebSocketException: wss://example.com/streaming?i=SECRET_TOKEN',
      );
      final scrubbed = scrubException(e).toString();
      expect(scrubbed, contains('i=***'));
      expect(scrubbed, isNot(contains('SECRET_TOKEN')));
    });
  });
}

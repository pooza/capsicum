import 'package:capsicum/src/util/exception_scrub.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
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

  group('debugLogException (#926)', () {
    // debugPrint を差し替えて出力を捕捉する。テスト後は必ず元へ戻す。
    late DebugPrintCallback original;
    late List<String> captured;

    setUp(() {
      original = debugPrint;
      captured = [];
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) captured.add(message);
      };
    });

    tearDown(() => debugPrint = original);

    test('生の例外を埋めず scrubException を必ず経由する', () {
      debugLogException(
        'capsicum: push failed',
        StateError('wss://example.com/streaming?i=SECRET_TOKEN'),
      );
      expect(captured, hasLength(1));
      expect(captured.single, startsWith('capsicum: push failed: '));
      expect(captured.single, contains('i=***'));
      expect(captured.single, isNot(contains('SECRET_TOKEN')));
    });

    test('DioException は type / status / path の要約に詰め替わる', () {
      debugLogException(
        'load failed',
        DioException(
          requestOptions: RequestOptions(
            path: '/api/miauth/3f2a1b9c-dead-beef/check',
          ),
          type: DioExceptionType.badResponse,
          response: Response(
            requestOptions: RequestOptions(path: '/'),
            statusCode: 400,
          ),
        ),
      );
      expect(captured.single, contains('DioException badResponse'));
      expect(captured.single, contains('/api/miauth/***/check'));
      expect(captured.single, isNot(contains('3f2a1b9c-dead-beef')));
    });

    test('stackTrace を渡すと改行して続ける', () {
      debugLogException(
        'restore failed',
        Exception('boom'),
        StackTrace.fromString('#0 frame'),
      );
      expect(captured.single, contains('restore failed: '));
      expect(captured.single, contains('\n#0 frame'));
    });
  });
}

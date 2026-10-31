import 'package:capsicum/src/provider/server_info_provider.dart';
import 'package:capsicum/src/util/sentry_server_software.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// #1337: Akkoma を Mastodon の一種として扱い、Sentry で見分ける。
class _MockDio extends Mock implements Dio {}

Response<dynamic> _resp(String path, dynamic data) => Response(
  requestOptions: RequestOptions(path: path),
  statusCode: 200,
  data: data,
);

/// [host] の NodeInfo を読ませ、ソフトウェア名を覚えさせる。
Future<void> _probe(String host, String name) async {
  final dio = _MockDio();
  final wellKnown = 'https://$host/.well-known/nodeinfo';
  final info = 'https://$host/nodeinfo/2.0';
  when(() => dio.get<dynamic>(wellKnown)).thenAnswer(
    (_) async => _resp(wellKnown, {
      'links': [
        {
          'rel': 'http://nodeinfo.diaspora.software/ns/schema/2.0',
          'href': info,
        },
      ],
    }),
  );
  when(() => dio.get<dynamic>(info)).thenAnswer(
    (_) async => _resp(info, {
      'software': {'name': name, 'version': '3.20.1'},
    }),
  );
  await probeInstance(dio, host);
}

void main() {
  group('Sentry の software タグ', () {
    test('host のタグから、NodeInfo で読めた名前を足す', () async {
      await _probe('akkoma.example', 'akkoma');

      final event = tagServerSoftware(
        SentryEvent(tags: {'host': 'akkoma.example', 'backend': 'mastodon'}),
      );

      expect(event.tags?[softwareTag], 'akkoma');
      expect(event.tags?['backend'], 'mastodon', reason: 'ほかのタグは残す');
    });

    test('⚠ ストリーミングの記録（stream.connect.host）にも足す', () async {
      await _probe('stream.example', 'akkoma');

      final event = tagServerSoftware(
        SentryEvent(tags: {'stream.connect.host': 'stream.example'}),
      );

      expect(event.tags?[softwareTag], 'akkoma');
    });

    test('読めていない host・host の無い記録には足さない', () {
      expect(
        tagServerSoftware(
          SentryEvent(tags: {'host': 'unknown.example'}),
        ).tags?.containsKey(softwareTag),
        isFalse,
      );
      expect(
        tagServerSoftware(
          SentryEvent(tags: {'host': '-'}),
        ).tags?.containsKey(softwareTag),
        isFalse,
      );
      expect(tagServerSoftware(SentryEvent()).tags, isNull);
    });

    test('⚠ 形のおかしい名前は足さない（長すぎる・使えない文字）(#1343)', () async {
      await _probe('long.example', 'a' * 65);
      await _probe('space.example', 'my server');
      await _probe('edge.example', 'a' * 64);

      bool tagged(String host) => tagServerSoftware(
        SentryEvent(tags: {'host': host}),
      ).tags!.containsKey(softwareTag);

      expect(tagged('long.example'), isFalse);
      expect(tagged('space.example'), isFalse);
      expect(tagged('edge.example'), isTrue, reason: '上限ちょうどは足す');
    });

    test('⚠ 記録を作る側が付けた software は上書きしない', () async {
      await _probe('mine.example', 'akkoma');

      final event = tagServerSoftware(
        SentryEvent(tags: {'host': 'mine.example', softwareTag: 'set'}),
      );

      expect(event.tags?[softwareTag], 'set');
    });
  });

  group('ヘルスチェックの「この確認は無い」', () {
    test('404 は口が無い', () {
      expect(
        isHealthEndpointMissing(
          DioException(
            requestOptions: RequestOptions(path: '/api/v1/streaming/health'),
            type: DioExceptionType.badResponse,
            response: Response(
              requestOptions: RequestOptions(path: '/api/v1/streaming/health'),
              statusCode: 404,
            ),
          ),
        ),
        isTrue,
      );
    });

    test('⚠ 500 や接続の失敗はエラーのまま', () {
      expect(
        isHealthEndpointMissing(
          DioException(
            requestOptions: RequestOptions(path: '/health'),
            type: DioExceptionType.badResponse,
            response: Response(
              requestOptions: RequestOptions(path: '/health'),
              statusCode: 500,
            ),
          ),
        ),
        isFalse,
      );
      expect(
        isHealthEndpointMissing(
          DioException(requestOptions: RequestOptions(path: '/health')),
        ),
        isFalse,
      );
    });

    test('HTML の応答（SPA の受け皿）は口が無い。本家の OK はそのまま', () {
      expect(looksLikeHtml('<!DOCTYPE html><html><head>'), isTrue);
      expect(looksLikeHtml('  <html lang="ja">'), isTrue);
      expect(looksLikeHtml('OK'), isFalse);
      expect(isHealthEndpointMissing(const HealthEndpointMissing()), isTrue);
    });
  });
}

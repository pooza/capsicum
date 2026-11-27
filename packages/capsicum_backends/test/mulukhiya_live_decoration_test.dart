import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1409: 実況のためにモロヘイヤが付けたデコ（mulukhiya#4912・5.48.0）。
///
/// ⚠ `features` に印は無いので、口が無いこと（Misskey 以外・5.48.0 より前）は
/// 404 で見分ける。
class _Adapter implements HttpClientAdapter {
  _Adapter({this.liveStatus = 200, this.restoreStatus = 200, this.live});

  final int liveStatus;
  final int restoreStatus;
  final Map<String, dynamic>? live;

  RequestOptions? liveRequest;
  RequestOptions? restoreRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path.endsWith('/decoration/live')) {
      liveRequest = options;
      return _json(live ?? {'live': false}, liveStatus);
    }
    if (path.endsWith('/decoration/restore')) {
      restoreRequest = options;
      return _json({'config': <String, dynamic>{}}, restoreStatus);
    }
    return _json({
      'package': {'version': '5.48.0'},
      'config': {'controller': 'misskey', 'features': <String, dynamic>{}},
    }, 200);
  }

  ResponseBody _json(Object body, int status) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );

  @override
  void close({bool force = false}) {}
}

Future<({MulukhiyaService service, _Adapter http})> _build({
  int liveStatus = 200,
  int restoreStatus = 200,
  Map<String, dynamic>? live,
}) async {
  final http = _Adapter(
    liveStatus: liveStatus,
    restoreStatus: restoreStatus,
    live: live,
  );
  final dio = Dio()..httpClientAdapter = http;
  final service = await MulukhiyaService.detect(dio, 'h.example');
  return (service: service!, http: http);
}

void main() {
  group('getLiveDecoration', () {
    test('bearer を付けて引き、応答を読む', () async {
      final built = await _build(
        live: {'live': true, 'id': 'd1', 'name': '実況中'},
      );
      final live = await built.service.getLiveDecoration(accessToken: 'tok');

      expect(built.http.liveRequest?.headers['Authorization'], 'Bearer tok');
      expect(live?.live, isTrue);
      expect(live?.id, 'd1');
    });

    test('⚠⚠ 404（口が無い）は null（出さない）', () async {
      final built = await _build(liveStatus: 404);
      expect(await built.service.getLiveDecoration(accessToken: 'tok'), isNull);
    });

    test('⚠ 404 以外の失敗は投げる（呼ぶ側が一過性として握る）', () async {
      final built = await _build(liveStatus: 500);
      await expectLater(
        built.service.getLiveDecoration(accessToken: 'tok'),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('restoreLiveDecoration', () {
    test('POST で外す', () async {
      final built = await _build();
      await built.service.restoreLiveDecoration(accessToken: 'tok');

      expect(built.http.restoreRequest?.method, 'POST');
      expect(built.http.restoreRequest?.headers['Authorization'], 'Bearer tok');
    });

    test('⚠ 404（もう外れている）は成功と同じに扱う', () async {
      final built = await _build(restoreStatus: 404);
      await expectLater(
        built.service.restoreLiveDecoration(accessToken: 'tok'),
        completes,
      );
    });
  });
}

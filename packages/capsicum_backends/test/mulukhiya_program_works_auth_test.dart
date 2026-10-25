import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1338: エピソードブラウザの作品検索とエピソード取得で、モロヘイヤに SNS の
/// トークンを送る。
///
/// Annict の API 利用規約（2026-11-25 施行・第 6 条）に合わせて、モロヘイヤが
/// `GET /program/works` と `GET /program/works/:id/episodes` に SNS の認証を
/// かける（mulukhiya-toot-proxy#4865）。⚠ 送らない版（v2.5 まで）は、認証を
/// かけた後のモロヘイヤで作品検索が「Annict 連携の案内」に化け、エピソードが
/// 取れなくなる。
class _Adapter implements HttpClientAdapter {
  final captured = <String, RequestOptions>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path.endsWith('/program/works')) {
      captured['works'] = options;
      return _json([
        {'annictId': 1, 'title': 'わんだふるぷりきゅあ！'},
      ]);
    }
    if (path.endsWith('/program/works/1/episodes')) {
      captured['episodes'] = options;
      return _json([
        {'annictId': 10, 'numberText': '第1話', 'title': 'いぬがすき'},
      ]);
    }
    return _json({
      'package': {'version': '5.43.0'},
      'config': {'controller': 'mastodon', 'features': <String, dynamic>{}},
    });
  }

  ResponseBody _json(Object body) => ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );

  @override
  void close({bool force = false}) {}
}

void main() {
  late _Adapter adapter;
  late MulukhiyaService service;

  setUp(() async {
    adapter = _Adapter();
    final dio = Dio()..httpClientAdapter = adapter;
    service = (await MulukhiyaService.detect(dio, 'h.example'))!;
  });

  test('⚠⚠ 作品の検索は SNS のトークンを Bearer で送る', () async {
    final works = await service.searchWorks(snsToken: 'tok123', keyword: 'わん');

    expect(works.single.title, 'わんだふるぷりきゅあ！');
    final request = adapter.captured['works']!;
    expect(request.headers['Authorization'], 'Bearer tok123');
    expect(request.uri.queryParameters['q'], 'わん');
  });

  test('⚠⚠ エピソードの取得も SNS のトークンを Bearer で送る', () async {
    final episodes = await service.getEpisodes(1, snsToken: 'tok123');

    expect(episodes.single.annictId, 10);
    expect(
      adapter.captured['episodes']!.headers['Authorization'],
      'Bearer tok123',
    );
  });
}

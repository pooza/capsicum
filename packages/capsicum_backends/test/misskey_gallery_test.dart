import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1053: ギャラリーの閲覧の充実（段階 1）。新着の一覧・いいね / 取り消し。
class _Server implements HttpClientAdapter {
  final requests = <({String path, Map<String, dynamic> body})>[];

  static Map<String, dynamic> _post(String id, {bool? isLiked}) => {
    'id': id,
    'title': 'title-$id',
    'createdAt': '2026-11-01T00:00:00.000Z',
    'user': {'id': 'u1', 'username': 'alice', 'host': null},
    'files': <Object>[],
    'isSensitive': false,
    'likedCount': 3,
    'isLiked': ?isLiked,
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var body = <String, dynamic>{};
    if (requestStream != null) {
      final bytes = (await requestStream.toList()).expand((c) => c).toList();
      if (bytes.isNotEmpty) {
        body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      }
    }
    requests.add((path: options.path, body: body));
    final Object response = switch (options.path) {
      '/api/gallery/posts' => [_post('p2', isLiked: true), _post('p1')],
      '/api/gallery/posts/like' || '/api/gallery/posts/unlike' => '',
      _ => <String, dynamic>{},
    };
    return ResponseBody.fromString(
      response is String ? response : jsonEncode(response),
      response is String ? 204 : 200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late MisskeyAdapter adapter;
  late _Server server;

  setUp(() async {
    adapter = await MisskeyAdapter.create('misskey.example');
    server = _Server();
    adapter.client.dio.httpClientAdapter = server;
  });

  test('新着は gallery/posts を untilId と limit で引く', () async {
    final posts = await adapter.getRecentGalleryPosts(
      query: const TimelineQuery(maxId: 'p9', limit: 20),
    );

    expect(server.requests.single.path, '/api/gallery/posts');
    expect(server.requests.single.body['untilId'], 'p9');
    expect(server.requests.single.body['limit'], 20);
    expect(posts.map((p) => p.id), ['p2', 'p1']);
  });

  test('isLiked は返ったときだけ読み、無ければ null（分からない）', () async {
    final posts = await adapter.getRecentGalleryPosts();

    expect(posts.first.isLiked, isTrue);
    expect(posts.last.isLiked, isNull);
  });

  test('いいね / 取り消しは postId を送る', () async {
    await adapter.likeGalleryPost('p1');
    await adapter.unlikeGalleryPost('p1');

    expect(server.requests.map((r) => r.path), [
      '/api/gallery/posts/like',
      '/api/gallery/posts/unlike',
    ]);
    expect(server.requests.first.body['postId'], 'p1');
    expect(server.requests.last.body['postId'], 'p1');
  });
}

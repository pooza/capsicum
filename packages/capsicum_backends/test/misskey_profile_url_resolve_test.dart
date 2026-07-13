import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// パスごとに固定レスポンスを返しつつ、叩かれたパスと body を記録する Adapter。
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.routes);

  /// path 部分文字列 -> (statusCode, body)。
  final Map<String, (int, Object)> routes;

  /// 叩かれた (path, decodedBody) の記録。
  final List<(String, Map<String, dynamic>)> calls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final data = options.data;
    calls.add((
      options.path,
      data is Map<String, dynamic>
          ? data
          : (data is String && data.isNotEmpty
                ? jsonDecode(data) as Map<String, dynamic>
                : <String, dynamic>{}),
    ));
    final entry = routes.entries.firstWhere(
      (e) => options.path.contains(e.key),
      orElse: () => throw StateError('no route for ${options.path}'),
    );
    final (status, body) = entry.value;
    return ResponseBody.fromString(
      body is String ? body : jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _alice = <String, dynamic>{'id': 'user1', 'username': 'alice'};
const _note = <String, dynamic>{
  'id': 'note1',
  'createdAt': '2026-06-02T00:00:00.000Z',
  'userId': 'user1',
  'user': {'id': 'user1', 'username': 'alice'},
  'visibility': 'public',
  'renoteCount': 0,
  'repliesCount': 0,
};

void main() {
  group('MisskeyAdapter.search プロフィール URL 解決 (#820)', () {
    test('ローカル /@username は users/show で解決し ap/show に依存しない', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      // ap/show は Misskey ローカルの /@username を解決できず 500 相当。
      // それでも users/show 経路で解決できることを確認する。
      final recorder = _RecordingAdapter({
        'users/show': (200, _alice),
        'ap/show': (500, {'error': 'unresolvable'}),
      });
      adapter.client.dio.httpClientAdapter = recorder;

      final results = await adapter.search('https://misskey.example/@alice');

      expect(results.users, hasLength(1));
      expect(results.users.first.username, 'alice');
      expect(results.posts, isEmpty);
      // users/show が叩かれ、ap/show には行っていない。
      final paths = recorder.calls.map((c) => c.$1).toList();
      expect(paths.any((p) => p.contains('users/show')), isTrue);
      expect(paths.any((p) => p.contains('ap/show')), isFalse);
      // ローカルなので host は付与しない。
      final showCall = recorder.calls.firstWhere(
        (c) => c.$1.contains('users/show'),
      );
      expect(showCall.$2['username'], 'alice');
      expect(showCall.$2.containsKey('host'), isFalse);
    });

    test('リモート /@user@host は users/show に host を渡す', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final recorder = _RecordingAdapter({'users/show': (200, _alice)});
      adapter.client.dio.httpClientAdapter = recorder;

      await adapter.search('https://misskey.example/@bob@remote.example');

      final showCall = recorder.calls.firstWhere(
        (c) => c.$1.contains('users/show'),
      );
      expect(showCall.$2['username'], 'bob');
      expect(showCall.$2['host'], 'remote.example');
    });

    test('ホスト無しでも別ホストの /@user は連合越しに host を渡す', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final recorder = _RecordingAdapter({'users/show': (200, _alice)});
      adapter.client.dio.httpClientAdapter = recorder;

      await adapter.search('https://other.example/@carol');

      final showCall = recorder.calls.firstWhere(
        (c) => c.$1.contains('users/show'),
      );
      expect(showCall.$2['username'], 'carol');
      expect(showCall.$2['host'], 'other.example');
    });

    test('投稿 URL /notes/xxx は従来どおり ap/show を通る', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final recorder = _RecordingAdapter({
        'ap/show': (200, {'type': 'Note', 'object': _note}),
      });
      adapter.client.dio.httpClientAdapter = recorder;

      final results = await adapter.search('https://misskey.example/notes/xxx');

      expect(results.posts, hasLength(1));
      final paths = recorder.calls.map((c) => c.$1).toList();
      expect(paths.any((p) => p.contains('ap/show')), isTrue);
      expect(paths.any((p) => p.contains('users/show')), isFalse);
    });

    test('/@user/pages/x はプロフィール扱いせず ap/show に委ねる', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final recorder = _RecordingAdapter({
        'ap/show': (200, {'type': 'User', 'object': _alice}),
      });
      adapter.client.dio.httpClientAdapter = recorder;

      await adapter.search('https://misskey.example/@alice/pages/foo');

      final paths = recorder.calls.map((c) => c.$1).toList();
      expect(paths.any((p) => p.contains('users/show')), isFalse);
      expect(paths.any((p) => p.contains('ap/show')), isTrue);
    });
  });
}

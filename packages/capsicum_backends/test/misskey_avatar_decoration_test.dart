import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1349: アイコンデコレーションの付け外し。
///
/// `/api/i` で今の値と上限を返し、`/api/i/update` は送られた配列を保存して返す
/// （[dropped] に入れた id は、権限のないものとして黙って落とす）。
class _Server implements HttpClientAdapter {
  _Server({required this.decorations, this.limit = 1, this.dropped = const {}});

  List<Map<String, dynamic>> decorations;
  final int? limit;
  final Set<String> dropped;
  List<dynamic>? lastUpdate;

  Map<String, dynamic> get _me => {
    'id': 'me',
    'username': 'me',
    'avatarDecorations': decorations,
    if (limit != null) 'policies': {'avatarDecorationLimit': limit},
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    Object body = _me;
    if (options.path.endsWith('/api/i/update')) {
      final data = options.data as Map<String, dynamic>;
      lastUpdate = data['avatarDecorations'] as List<dynamic>;
      decorations = [
        for (final d in lastUpdate!.cast<Map<String, dynamic>>())
          if (!dropped.contains(d['id'])) {...d, 'url': 'https://x/${d['id']}'},
      ];
      body = _me;
    } else if (options.path.endsWith('/api/get-avatar-decorations')) {
      body = [
        {'id': 'a', 'name': 'かぼちゃ', 'url': 'https://x/a'},
        {'id': '', 'name': '壊れた行', 'url': 'https://x/b'},
      ];
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _adjusted = {
  'id': 'keep',
  'url': 'https://x/keep',
  'angle': 0.1,
  'flipH': true,
  'offsetX': 0.2,
  'offsetY': -0.2,
};

void main() {
  late MisskeyAdapter adapter;

  Future<_Server> install(_Server server) async {
    adapter = await MisskeyAdapter.create('misskey.example');
    adapter.client.dio.httpClientAdapter = server;
    return server;
  }

  test('一覧は id と url の無い行を落とす', () async {
    await install(_Server(decorations: []));

    final options = await adapter.getAvatarDecorationOptions();

    expect(options.single.name, 'かぼちゃ');
  });

  test('⚠⚠ 付けたままのものは調整値を添えて送る（Web の調整を崩さない）', () async {
    final server = await install(_Server(decorations: [_adjusted], limit: 3));

    await adapter.attachAvatarDecoration('new');

    final sent = server.lastUpdate!.cast<Map<String, dynamic>>();
    expect(sent.first, {
      'id': 'keep',
      'angle': 0.1,
      'flipH': true,
      'offsetX': 0.2,
      'offsetY': -0.2,
    });
    expect(sent.last, {'id': 'new'});
  });

  test('外すときも、残すものの調整値を添える', () async {
    final server = await install(
      _Server(
        decorations: [
          _adjusted,
          {'id': 'drop', 'url': 'https://x/drop'},
        ],
        limit: 3,
      ),
    );

    await adapter.detachAvatarDecoration('drop');

    final sent = server.lastUpdate!.cast<Map<String, dynamic>>();
    expect(sent.single['id'], 'keep');
    expect(sent.single['offsetX'], 0.2);
  });

  test('全部外すと空の配列を送る', () async {
    final server = await install(_Server(decorations: [_adjusted]));

    final user = await adapter.detachAvatarDecoration('keep');

    expect(server.lastUpdate, isEmpty);
    expect(user.avatarDecorations, isEmpty);
  });

  test('上限が 1 なら入れ替える', () async {
    final server = await install(_Server(decorations: [_adjusted]));

    final user = await adapter.attachAvatarDecoration('new');

    expect(server.lastUpdate, [
      {'id': 'new'},
    ]);
    expect(user.avatarDecorations.single.id, 'new');
  });

  test('上限が 2 以上で埋まっていたら、送らずに知らせる', () async {
    final server = await install(
      _Server(
        decorations: [
          _adjusted,
          {'id': 'b', 'url': 'https://x/b'},
        ],
        limit: 2,
      ),
    );

    await expectLater(
      adapter.attachAvatarDecoration('new'),
      throwsA(
        isA<AvatarDecorationLimitReached>().having((e) => e.limit, 'limit', 2),
      ),
    );
    expect(server.lastUpdate, isNull);
  });

  test('⚠⚠ 黙って落とされたら、付いたことにしない', () async {
    await install(_Server(decorations: [], limit: 3, dropped: {'locked'}));

    await expectLater(
      adapter.attachAvatarDecoration('locked'),
      throwsA(isA<AvatarDecorationRejected>()),
    );
  });

  test('上限が読めなくても送る（判定はサーバーに任せる）', () async {
    final server = await install(
      _Server(decorations: [_adjusted], limit: null),
    );

    await adapter.attachAvatarDecoration('new');

    expect(server.lastUpdate, hasLength(2));
  });

  test('もう付いていれば送らない', () async {
    final server = await install(_Server(decorations: [_adjusted], limit: 3));

    await adapter.attachAvatarDecoration('keep');

    expect(server.lastUpdate, isNull);
  });
}

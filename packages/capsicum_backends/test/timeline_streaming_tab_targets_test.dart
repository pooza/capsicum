import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// #1098: タグ / リスト / チャンネルのカラムを購読できること（B-5）。
///
/// ⚠⚠ **デッキの主役はこの 3 種。**タグ TL を何本も並べるのが実況用途なので、
/// 購読が張られないと「並べたのに動かない」になる。
///
/// ⚠⚠ **Misskey の `hashtag` / `userList` / `channel` は `params` が要る。**
/// 欠けても**例外にはならず `init` が `false` を返すだけ**で、購読が黙って
/// 張られない（#1089 で踏んだ「黙って止まる」と同型）。だから
/// **`connect` フレームの中身まで見る**。
///
/// ⚠ **Mastodon には AND 指定のタグもチャンネルも無い。**代表タグだけで繋ぐと
/// AND を満たさない投稿がカラムへ流れ込むので、**繋がないことを固定する**。
void main() {
  late HttpServer server;
  late List<_Connection> connections;

  setUp(() async {
    connections = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      connections.add(_Connection(request.uri, socket));
    });
  });

  tearDown(() async {
    for (final c in connections) {
      await c.socket.close();
    }
    await server.close(force: true);
  });

  WebSocketChannel toLocal(Uri uri) => IOWebSocketChannel.connect(
    uri.replace(scheme: 'ws', host: '127.0.0.1', port: server.port),
  );

  Future<void> waitForConnections(int count) async {
    for (var i = 0; i < 200 && connections.length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(connections, hasLength(count), reason: '前提: 接続が張られている');
  }

  /// 繋がないことの確認。張られないことは「まだ張られていない」と見分けが
  /// つかないので、接続が起きるだけの時間を待ってから 0 本を見る。
  Future<void> expectNoConnection() async {
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(connections, isEmpty, reason: '購読を張ってはいけない');
    }
  }

  group('Mastodon', () {
    Future<MastodonAdapter> makeAdapter() async {
      final adapter = await MastodonAdapter.create('mstdn.example');
      adapter.client.setAccessToken('token');
      adapter.timelineChannelFactory = toLocal;
      return adapter;
    }

    String update(String id) => jsonEncode({
      'event': 'update',
      'payload': jsonEncode(_mastodonStatus(id)),
    });

    test('ハッシュタグのカラムは stream=hashtag&tag=... で繋ぎ、投稿が届く', () async {
      final adapter = await makeAdapter();
      final posts = _Collector(
        adapter.streamTimeline(
          'me|hashtag:precure_fun',
          HashtagTab('precure_fun'),
        ),
      );
      addTearDown(() => adapter.disposeStream('me|hashtag:precure_fun'));
      await waitForConnections(1);

      final query = connections.single.uri.queryParameters;
      expect(query['stream'], 'hashtag');
      expect(query['tag'], 'precure_fun', reason: 'タグを載せないと全公開 TL になる');

      connections.single.socket.add(update('t1'));
      expect(await posts.next(), 't1');
    });

    test('リストのカラムは stream=list&list=... で繋ぐ', () async {
      final adapter = await makeAdapter();
      adapter.streamTimeline('me|list:42', const ListTab(id: '42'));
      addTearDown(() => adapter.disposeStream('me|list:42'));
      await waitForConnections(1);

      final query = connections.single.uri.queryParameters;
      expect(query['stream'], 'list');
      expect(query['list'], '42');
    });

    test('⚠⚠ AND 指定のタグは購読しない（代表タグだけで繋ぐと AND 外が流れ込む）', () async {
      final adapter = await makeAdapter();
      final stream = adapter.streamTimeline(
        'me|hashtag:delmulin+capsicum',
        HashtagTab('delmulin+capsicum'),
      );
      expect(await stream.isEmpty, isTrue);
      await expectNoConnection();
    });

    test('⚠ チャンネルは Mastodon に無いので購読しない', () async {
      final adapter = await makeAdapter();
      final stream = adapter.streamTimeline(
        'me|channel:abc',
        const ChannelTab(id: 'abc'),
      );
      expect(await stream.isEmpty, isTrue);
      await expectNoConnection();
    });

    test('⚠ DM も専用ストリームが無いので購読しない（user へ落とさない・#793）', () async {
      final adapter = await makeAdapter();
      final stream = adapter.streamTimeline(
        'me|timeline:directMessages',
        const TimelineTab(TimelineType.directMessages),
      );
      expect(await stream.isEmpty, isTrue);
      await expectNoConnection();
    });
  });

  group('Misskey', () {
    Future<MisskeyAdapter> makeAdapter() async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.setAccessToken('token');
      adapter.timelineChannelFactory = toLocal;
      return adapter;
    }

    /// クライアントが送った `connect` フレームの body。
    Future<Map<String, dynamic>> connectBody(_Connection c) async {
      final frame = await c.messages.first.timeout(const Duration(seconds: 5));
      final json = jsonDecode(frame as String) as Map<String, dynamic>;
      expect(json['type'], 'connect');
      return json['body'] as Map<String, dynamic>;
    }

    String note(String subId, String id) => jsonEncode({
      'type': 'channel',
      'body': {'id': subId, 'type': 'note', 'body': _misskeyNote(id)},
    });

    test('⚠⚠ ハッシュタグは channel=hashtag + params.q で購読し、投稿が届く', () async {
      final adapter = await makeAdapter();
      final posts = _Collector(
        adapter.streamTimeline(
          'me|hashtag:precure_fun',
          HashtagTab('precure_fun'),
        ),
      );
      addTearDown(() => adapter.disposeStream('me|hashtag:precure_fun'));
      await waitForConnections(1);

      final body = await connectBody(connections.single);
      expect(body['channel'], 'hashtag');
      expect(body['params'], {
        'q': [
          ['precure_fun'],
        ],
      }, reason: '⚠⚠ params.q が無いと init が false を返し、例外なしに購読が張られない');

      connections.single.socket.add(note(body['id'] as String, 't1'));
      expect(await posts.next(), 't1');
    });

    test('AND 指定は q の内側に並べる（AND の OR）', () async {
      final adapter = await makeAdapter();
      adapter.streamTimeline(
        'me|hashtag:delmulin+capsicum',
        HashtagTab('delmulin+capsicum'),
      );
      addTearDown(() => adapter.disposeStream('me|hashtag:delmulin+capsicum'));
      await waitForConnections(1);

      final body = await connectBody(connections.single);
      expect(body['params'], {
        'q': [
          ['delmulin', 'capsicum'],
        ],
      });
    });

    test('リストは channel=userList + listId で購読する', () async {
      final adapter = await makeAdapter();
      adapter.streamTimeline('me|list:42', const ListTab(id: '42'));
      addTearDown(() => adapter.disposeStream('me|list:42'));
      await waitForConnections(1);

      final body = await connectBody(connections.single);
      expect(body['channel'], 'userList');
      expect(body['params'], {'listId': '42'});
    });

    test('チャンネルは channel=channel + channelId で購読する', () async {
      final adapter = await makeAdapter();
      adapter.streamTimeline('me|channel:abc', const ChannelTab(id: 'abc'));
      addTearDown(() => adapter.disposeStream('me|channel:abc'));
      await waitForConnections(1);

      final body = await connectBody(connections.single);
      expect(body['channel'], 'channel');
      expect(body['params'], {'channelId': 'abc'});
    });

    test('⚠ DM はチャンネルが無いので購読しない（homeTimeline へ化けない・#793）', () async {
      final adapter = await makeAdapter();
      final stream = adapter.streamTimeline(
        'me|timeline:directMessages',
        const TimelineTab(TimelineType.directMessages),
      );
      expect(await stream.isEmpty, isTrue);
      await expectNoConnection();
    });
  });
}

class _Connection {
  _Connection(this.uri, this.socket) : messages = socket.asBroadcastStream();

  final Uri uri;
  final WebSocket socket;

  /// クライアントから届いたフレーム。
  final Stream<dynamic> messages;
}

class _Collector {
  _Collector(Stream<Post> stream) {
    stream.listen((post) => _queue.add(post.id));
  }

  final _queue = StreamController<String>();
  late final _ids = StreamIterator(_queue.stream);

  Future<String> next() async {
    final has = await _ids.moveNext().timeout(const Duration(seconds: 5));
    expect(has, isTrue);
    return _ids.current;
  }
}

Map<String, dynamic> _mastodonStatus(String id) => {
  'id': id,
  'created_at': '2026-09-19T00:00:00Z',
  'account': {
    'id': '1',
    'username': 'someone',
    'acct': 'someone',
    'display_name': 'someone',
    'note': '',
    'avatar': '',
    'header': '',
    'followers_count': 0,
    'following_count': 0,
    'statuses_count': 0,
    'fields': <Map<String, dynamic>>[],
  },
  'content': '<p>body</p>',
  'visibility': 'public',
  'favourites_count': 0,
  'reblogs_count': 0,
  'replies_count': 0,
  'media_attachments': <Map<String, dynamic>>[],
};

Map<String, dynamic> _misskeyNote(String id) => {
  'id': id,
  'createdAt': '2026-09-19T00:00:00.000Z',
  'userId': 'other',
  'user': {'id': 'other', 'username': 'someone'},
  'text': 'body',
  'visibility': 'public',
  'renoteCount': 0,
  'repliesCount': 0,
};

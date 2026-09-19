import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// #1089 / #1090: 同じアカウントで本線 TL を複数同時に購読できること。
///
/// ⚠⚠ 以前はアダプタが購読を**単数**で持ち、2 本目を張ると 1 本目が**黙って
/// 止まっていた**（`docs/deck-ui-plan.md` B-1）。デッキで同じアカウントの home と
/// local を並べると、片方しかライブにならない。例外にもならないので気づけない。
///
/// ⚠ それまで streaming の接続を固定するテストは 1 本も無かった（計算とパースだけ）。
/// ここでは**ローカルの WebSocket サーバーへ実際に 2 本つなぎ**、サーバーから
/// 送ったイベントが両方の購読に届き続けることを見る。
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

  /// アダプタが組み立てた `wss://<host>/...` を、パスとクエリを保ったまま
  /// ローカルのサーバーへ向け直す。
  WebSocketChannel toLocal(Uri uri) => IOWebSocketChannel.connect(
    uri.replace(scheme: 'ws', host: '127.0.0.1', port: server.port),
  );

  /// [count] 本の接続が張られるまで待つ。
  Future<void> waitForConnections(int count) async {
    for (var i = 0; i < 200 && connections.length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(connections, hasLength(count), reason: '前提: 接続が張られている');
  }

  group('Mastodon (#1090)', () {
    String update(String id) => jsonEncode({
      'event': 'update',
      'payload': jsonEncode(_mastodonStatus(id)),
    });

    _Connection streamOf(String name) =>
        connections.singleWhere((c) => c.uri.queryParameters['stream'] == name);

    Future<MastodonAdapter> makeAdapter() async {
      final adapter = await MastodonAdapter.create('mstdn.example');
      adapter.client.setAccessToken('token');
      adapter.timelineChannelFactory = toLocal;
      return adapter;
    }

    test('⚠⚠ 2 本目を購読しても 1 本目にイベントが届き続ける', () async {
      final adapter = await makeAdapter();
      final home = _Collector(
        adapter.streamTimeline(
          'me|timeline:home',
          TimelineTab(TimelineType.home),
        ),
      );
      final local = _Collector(
        adapter.streamTimeline(
          'me|timeline:local',
          TimelineTab(TimelineType.local),
        ),
      );
      addTearDown(() {
        adapter.disposeStream('me|timeline:home');
        adapter.disposeStream('me|timeline:local');
      });
      await waitForConnections(2);

      streamOf('user').socket.add(update('h1'));
      streamOf('public:local').socket.add(update('l1'));

      expect(await home.next(), 'h1', reason: '先に張った home が止まっていない');
      expect(await local.next(), 'l1');
    });

    test('片方を閉じても、もう片方には届き続ける', () async {
      final adapter = await makeAdapter();
      final home = _Collector(
        adapter.streamTimeline(
          'me|timeline:home',
          TimelineTab(TimelineType.home),
        ),
      );
      adapter.streamTimeline(
        'me|timeline:local',
        TimelineTab(TimelineType.local),
      );
      addTearDown(() => adapter.disposeStream('me|timeline:home'));
      await waitForConnections(2);

      adapter.disposeStream('me|timeline:local');
      streamOf('user').socket.add(update('h2'));

      expect(await home.next(), 'h2');
    });

    test('同じキーで張り直すと、そのキーの前の購読だけが閉じる', () async {
      final adapter = await makeAdapter();
      final home = _Collector(
        adapter.streamTimeline(
          'me|timeline:home',
          TimelineTab(TimelineType.home),
        ),
      );
      adapter.streamTimeline(
        'me|timeline:local',
        TimelineTab(TimelineType.local),
      );
      addTearDown(() {
        adapter.disposeStream('me|timeline:home');
        adapter.disposeStream('me|timeline:local');
      });
      await waitForConnections(2);

      // local を張り直す（pull-to-refresh 等で build() がやり直された形）。
      final local = _Collector(
        adapter.streamTimeline(
          'me|timeline:local',
          TimelineTab(TimelineType.local),
        ),
      );
      await waitForConnections(3);

      connections.last.socket.add(update('l2'));
      streamOf('user').socket.add(update('h3'));

      expect(await local.next(), 'l2');
      expect(await home.next(), 'h3', reason: '別のキーの購読は張り直しに巻き込まれない');
    });
  });

  group('Misskey (#1089)', () {
    /// サーバー側で受け取った `connect` フレームから購読 id を取り出す。
    Future<String> subscriptionIdOf(_Connection c) async {
      final frame = await c.messages.first.timeout(const Duration(seconds: 5));
      final json = jsonDecode(frame as String) as Map<String, dynamic>;
      expect(json['type'], 'connect');
      return (json['body'] as Map<String, dynamic>)['id'] as String;
    }

    String note(String subId, String id) => jsonEncode({
      'type': 'channel',
      'body': {'id': subId, 'type': 'note', 'body': _misskeyNote(id)},
    });

    Future<MisskeyAdapter> makeAdapter() async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      adapter.client.setAccessToken('token');
      adapter.timelineChannelFactory = toLocal;
      return adapter;
    }

    test('⚠⚠ 2 本目を購読しても 1 本目にイベントが届き続ける', () async {
      final adapter = await makeAdapter();
      final home = _Collector(
        adapter.streamTimeline(
          'me|timeline:home',
          TimelineTab(TimelineType.home),
        ),
      );
      await waitForConnections(1);
      final homeConn = connections[0];
      final homeSub = await subscriptionIdOf(homeConn);

      final local = _Collector(
        adapter.streamTimeline(
          'me|timeline:local',
          TimelineTab(TimelineType.local),
        ),
      );
      addTearDown(() {
        adapter.disposeStream('me|timeline:home');
        adapter.disposeStream('me|timeline:local');
      });
      await waitForConnections(2);
      final localConn = connections[1];
      final localSub = await subscriptionIdOf(localConn);

      homeConn.socket.add(note(homeSub, 'h1'));
      localConn.socket.add(note(localSub, 'l1'));

      expect(await home.next(), 'h1', reason: '先に張った home が止まっていない');
      expect(await local.next(), 'l1');
    });

    test('片方を閉じても、もう片方には届き続ける', () async {
      final adapter = await makeAdapter();
      final home = _Collector(
        adapter.streamTimeline(
          'me|timeline:home',
          TimelineTab(TimelineType.home),
        ),
      );
      await waitForConnections(1);
      final homeConn = connections[0];
      final homeSub = await subscriptionIdOf(homeConn);
      adapter.streamTimeline(
        'me|timeline:local',
        TimelineTab(TimelineType.local),
      );
      addTearDown(() => adapter.disposeStream('me|timeline:home'));
      await waitForConnections(2);

      adapter.disposeStream('me|timeline:local');
      homeConn.socket.add(note(homeSub, 'h2'));

      expect(await home.next(), 'h2');
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

/// 購読に届いた投稿を id で受け取る。
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
  'created_at': '2026-09-17T00:00:00Z',
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
  'createdAt': '2026-09-17T00:00:00.000Z',
  'userId': 'other',
  'user': {'id': 'other', 'username': 'someone'},
  'text': 'body',
  'visibility': 'public',
  'renoteCount': 0,
  'repliesCount': 0,
};

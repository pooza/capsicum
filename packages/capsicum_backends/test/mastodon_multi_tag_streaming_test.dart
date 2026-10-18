import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:capsicum_backends/src/mastodon/streaming.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

/// #1277: 条件が 2 つ以上あるタグ TL にも、Mastodon でライブ更新を張る。
///
/// Mastodon の `hashtag` ストリームはタグ 1 つしか受けないので、以前は張って
/// いなかった（引っ張って更新するまで新着が出なかった）。**1 本の接続に、タグごとの
/// 購読を載せる。**ここでは実際にローカルの WebSocket サーバーへつなぎ、送る購読と
/// 重複の落とし方を見る。
void main() {
  Map<String, dynamic> account() => {
    'id': '99',
    'username': 'u99',
    'acct': 'u99@example.com',
    'display_name': 'user',
    'note': '',
    'avatar': '',
    'header': '',
    'followers_count': 0,
    'following_count': 0,
    'statuses_count': 0,
    'fields': <Map<String, dynamic>>[],
  };

  Map<String, dynamic> status(String id) => {
    'id': id,
    'uri': 'https://example.com/statuses/$id',
    'created_at': '2026-10-18T00:00:00.000Z',
    'content': 'hello',
    'visibility': 'public',
    'sensitive': false,
    'spoiler_text': '',
    'account': account(),
    'media_attachments': <Map<String, dynamic>>[],
    'mentions': <Map<String, dynamic>>[],
    'tags': <Map<String, dynamic>>[],
    'emojis': <Map<String, dynamic>>[],
    'reblogs_count': 0,
    'favourites_count': 0,
    'replies_count': 0,
  };

  late HttpServer server;
  late List<Uri> connectedUris;
  late List<Map<String, dynamic>> received;
  late Completer<WebSocket> socket;

  setUp(() async {
    connectedUris = [];
    received = [];
    socket = Completer<WebSocket>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      connectedUris.add(request.uri);
      final ws = await WebSocketTransformer.upgrade(request);
      ws.listen((data) {
        received.add(jsonDecode(data as String) as Map<String, dynamic>);
      });
      if (!socket.isCompleted) socket.complete(ws);
    });
  });

  tearDown(() => server.close(force: true));

  MastodonStreaming streaming() => MastodonStreaming(
    host: 'example.com',
    accessToken: 'token',
    channelFactory: (uri) => IOWebSocketChannel.connect(
      uri.replace(scheme: 'ws', host: '127.0.0.1', port: server.port),
    ),
  );

  Future<void> waitUntil(bool Function() condition) async {
    for (var i = 0; i < 300 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  void sendUpdate(WebSocket ws, String tag, String id) => ws.add(
    jsonEncode({
      'stream': ['hashtag', tag],
      'event': 'update',
      'payload': jsonEncode(status(id)),
    }),
  );

  group('購読するタグ', () {
    test('1 つだけなら null（接続の URL で張る）', () {
      expect(mastodonHashtagSubscriptions(const HashtagTab('a')), isNull);
    });

    test('「いずれか」があればその全部', () {
      expect(mastodonHashtagSubscriptions(const HashtagTab('?a+b')), [
        'a',
        'b',
      ]);
    });

    test('「すべて含む」だけなら先頭 1 つ', () {
      expect(mastodonHashtagSubscriptions(const HashtagTab('a+b')), ['a']);
    });

    test('⚠⚠ 端末側で確かめられないタグが残りにあれば張らない', () {
      // 全角英数はサーバーの正規化で半角になる（端末側の比較が当てにならない）。
      expect(mastodonHashtagSubscriptions(const HashtagTab('a+Ｂ')), isNull);
      expect(mastodonHashtagSubscriptions(const HashtagTab('a!Ｂ')), isNull);
      expect(mastodonCanStream(const HashtagTab('a+Ｂ')), isFalse);
      // 購読する側（「いずれか」）は確かめないので、全角でも張れる。
      expect(mastodonHashtagSubscriptions(const HashtagTab('?Ａ+b')), [
        'Ａ',
        'b',
      ]);
    });

    test('除外があっても、張るのは含む側', () {
      expect(mastodonHashtagSubscriptions(const HashtagTab('a!b')), ['a']);
    });

    test('⚠⚠ 以前は張っていなかった条件も、張れる', () {
      expect(mastodonCanStream(const HashtagTab('a+b')), isTrue);
      expect(mastodonCanStream(const HashtagTab('?a+b')), isTrue);
    });
  });

  test('⚠⚠ 1 本の接続に、タグごとの購読を送る（stream は URL に載せない）', () async {
    final s = streaming();
    final sub = s.connect(const HashtagTab('?a+b')).listen((_) {});
    addTearDown(() async {
      await sub.cancel();
      s.dispose();
    });

    await socket.future;
    await waitUntil(() => received.length >= 2);

    expect(connectedUris, hasLength(1), reason: '接続は増やさない');
    expect(connectedUris.single.queryParameters.containsKey('stream'), isFalse);
    expect(received, [
      {'type': 'subscribe', 'stream': 'hashtag', 'tag': 'a'},
      {'type': 'subscribe', 'stream': 'hashtag', 'tag': 'b'},
    ]);
  });

  test('⚠⚠ 両方のタグから届いた同じ投稿は 1 回だけ流す', () async {
    final s = streaming();
    final posts = <Post>[];
    final sub = s.connect(const HashtagTab('?a+b')).listen(posts.add);
    addTearDown(() async {
      await sub.cancel();
      s.dispose();
    });

    final ws = await socket.future;
    await waitUntil(() => received.length >= 2);
    sendUpdate(ws, 'a', '1');
    sendUpdate(ws, 'b', '1');
    sendUpdate(ws, 'b', '2');
    await waitUntil(() => posts.length >= 2);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(posts.map((p) => p.id), ['1', '2']);
  });

  test('タグ 1 つは従来どおり URL で張り、購読は送らない', () async {
    final s = streaming();
    final sub = s.connect(const HashtagTab('a')).listen((_) {});
    addTearDown(() async {
      await sub.cancel();
      s.dispose();
    });

    await socket.future;
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(connectedUris.single.queryParameters['stream'], 'hashtag');
    expect(connectedUris.single.queryParameters['tag'], 'a');
    expect(received, isEmpty);
  });
}

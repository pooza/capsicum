import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1206: Mastodon の DM（会話）を既読にする・一覧から削除する。
///
/// capsicum は DM を投稿の列として出しているので、**投稿から会話を引けること**
/// が前提になる。会話の id は投稿の id とは別物で、取り違えると別の会話を
/// 既読にしたり消したりする。
class _Recorder implements HttpClientAdapter {
  _Recorder(this.conversations);

  final List<Map<String, dynamic>> conversations;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final isIndex =
        options.method == 'GET' && options.path == '/api/v1/conversations';
    return ResponseBody.fromString(
      jsonEncode(isIndex ? conversations : <String, dynamic>{}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _status(String id) => {
  'id': id,
  'created_at': '2026-10-09T00:00:00Z',
  'account': {
    'id': '1',
    'username': 'alice',
    'acct': 'alice',
    'display_name': 'alice',
    'note': '',
    'avatar': '',
    'header': '',
    'followers_count': 0,
    'following_count': 0,
    'statuses_count': 0,
    'fields': <Map<String, dynamic>>[],
  },
  'content': '<p>dm</p>',
  'visibility': 'direct',
  'favourites_count': 0,
  'reblogs_count': 0,
  'replies_count': 0,
  'media_attachments': <Map<String, dynamic>>[],
};

Map<String, dynamic> _conversation(
  String id, {
  required bool unread,
  String? lastStatusId,
}) => {
  'id': id,
  'unread': unread,
  'accounts': <Object>[],
  'last_status': lastStatusId == null ? null : _status(lastStatusId),
};

void main() {
  late MastodonAdapter adapter;
  late _Recorder recorder;

  Future<void> boot(List<Map<String, dynamic>> conversations) async {
    adapter = await MastodonAdapter.create('example.com');
    recorder = _Recorder(conversations);
    adapter.client.dio.httpClientAdapter = recorder;
    await adapter.getTimeline(TimelineType.directMessages);
    recorder.requests.clear();
  }

  test('DM 一覧を取得すると、投稿から会話と未読を引ける', () async {
    await boot([
      _conversation('c10', unread: true, lastStatusId: 's100'),
      _conversation('c11', unread: false, lastStatusId: 's101'),
    ]);

    // ⚠ 会話の id（c10）と投稿の id（s100）は別物。
    expect(adapter.conversationOf('s100')?.id, 'c10');
    expect(adapter.conversationOf('s100')?.unread, isTrue);
    expect(adapter.conversationOf('s101')?.id, 'c11');
    expect(adapter.conversationOf('s101')?.unread, isFalse);
  });

  test('DM 一覧で見ていない投稿には会話が無い', () async {
    await boot([_conversation('c10', unread: true, lastStatusId: 's100')]);

    expect(adapter.conversationOf('s999'), isNull);
  });

  test('last_status が無い会話は、投稿の列にも対応にも入らない', () async {
    await boot([
      _conversation('c10', unread: true),
      _conversation('c11', unread: true, lastStatusId: 's101'),
    ]);

    expect(adapter.conversationOf('s101')?.id, 'c11');
  });

  test('既読は会話の id で conversations/:id/read を叩く', () async {
    await boot([_conversation('c10', unread: true, lastStatusId: 's100')]);

    await adapter.markConversationRead('c10');

    final request = recorder.requests.single;
    expect(request.method, 'POST');
    expect(request.path, '/api/v1/conversations/c10/read');
  });

  test('⚠ 既読にしたら手元の未読も倒れる（開くたびに呼び直さない）', () async {
    await boot([
      _conversation('c10', unread: true, lastStatusId: 's100'),
      _conversation('c11', unread: true, lastStatusId: 's101'),
    ]);

    await adapter.markConversationRead('c10');

    expect(adapter.conversationOf('s100')?.unread, isFalse);
    // ⚠ 別の会話は巻き込まない。
    expect(adapter.conversationOf('s101')?.unread, isTrue);
  });

  test('削除は会話の id で DELETE し、対応からも外す', () async {
    await boot([
      _conversation('c10', unread: false, lastStatusId: 's100'),
      _conversation('c11', unread: false, lastStatusId: 's101'),
    ]);

    await adapter.deleteConversation('c10');

    final request = recorder.requests.single;
    expect(request.method, 'DELETE');
    // ⚠⚠ 投稿を消す `/api/v1/statuses/:id` ではない。
    expect(request.path, '/api/v1/conversations/c10');
    expect(adapter.conversationOf('s100'), isNull);
    expect(adapter.conversationOf('s101')?.id, 'c11');
  });

  test('ページングのカーソルは従来どおり最後の会話の id', () async {
    adapter = await MastodonAdapter.create('example.com');
    recorder = _Recorder([
      _conversation('c10', unread: true, lastStatusId: 's100'),
      _conversation('c9', unread: false),
    ]);
    adapter.client.dio.httpClientAdapter = recorder;

    final response = await adapter.getTimeline(TimelineType.directMessages);

    expect(response.posts.map((p) => p.id), ['s100']);
    expect(response.rawLastId, 'c9');
  });
}

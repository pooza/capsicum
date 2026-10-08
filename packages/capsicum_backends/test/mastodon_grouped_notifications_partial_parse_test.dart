import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1236: グループ通知（`GET /api/v2/notifications`）は、1 要素が読めないだけで
/// ページ全体を落とさない。
///
/// ⚠⚠ 以前は応答を一括で `fromJson` していたので、`accounts[]` / `statuses[]` /
/// `notification_groups[]` のどれか 1 要素が壊れていると、**そのページを含む
/// 通知一覧が丸ごとエラー**になった。v1 は同じ理由で要素ごとに守ってある。
class _Fixed implements HttpClientAdapter {
  _Fixed(this.body);

  final Object body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
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
  Map<String, dynamic> account(String id) => {
    'id': id,
    'username': 'u$id',
    'acct': 'u$id@example.com',
    'display_name': 'user $id',
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
    'created_at': '2026-10-08T00:00:00.000Z',
    'content': 'hello',
    'visibility': 'public',
    'sensitive': false,
    'spoiler_text': '',
    'account': account('99'),
    'media_attachments': <Map<String, dynamic>>[],
    'mentions': <Map<String, dynamic>>[],
    'tags': <Map<String, dynamic>>[],
    'emojis': <Map<String, dynamic>>[],
    'reblogs_count': 0,
    'favourites_count': 0,
    'replies_count': 0,
  };

  Map<String, dynamic> group(String key, {String notificationId = '10'}) => {
    'group_key': key,
    'notifications_count': 1,
    'type': 'favourite',
    'most_recent_notification_id': notificationId,
    'page_min_id': notificationId,
    'page_max_id': notificationId,
    'latest_page_notification_at': '2026-10-08T00:00:00.000Z',
    'sample_account_ids': ['1'],
    'status_id': '100',
  };

  Future<MastodonAdapter> adapterReturning(Map<String, dynamic> body) async {
    final adapter = await MastodonAdapter.create('example.com');
    adapter.client.dio.httpClientAdapter = _Fixed(body);
    return adapter;
  }

  test('前提: 壊れた要素が無ければ全部読める', () async {
    final adapter = await adapterReturning({
      'accounts': [account('1')],
      'statuses': [status('100')],
      'notification_groups': [group('a'), group('b', notificationId: '9')],
    });
    final grouped = await adapter.client.getGroupedNotifications();
    expect(grouped.accounts, hasLength(1));
    expect(grouped.statuses, hasLength(1));
    expect(grouped.notificationGroups, hasLength(2));
  });

  test('⚠⚠ 壊れたグループが 1 つあっても、残りのグループは読める', () async {
    final adapter = await adapterReturning({
      'accounts': [account('1')],
      'statuses': [status('100')],
      'notification_groups': [
        group('a'),
        // group_key が無い ＝ fromJson が TypeError を投げる。
        {'type': 'favourite', 'notifications_count': 1},
        group('c', notificationId: '8'),
      ],
    });
    final grouped = await adapter.client.getGroupedNotifications();
    expect(grouped.notificationGroups.map((g) => g.groupKey), ['a', 'c']);
  });

  test('⚠⚠ 壊れたアカウント・投稿が 1 つあっても、ほかは読める', () async {
    final adapter = await adapterReturning({
      'accounts': [
        account('1'),
        {'id': 2}, // id が数値・必須の項目も無い。
      ],
      'statuses': ['not a map', status('100')],
      'notification_groups': [group('a')],
    });
    final grouped = await adapter.client.getGroupedNotifications();
    expect(grouped.accounts.map((a) => a.id), ['1']);
    expect(grouped.statuses.map((s) => s.id), ['100']);
    expect(grouped.notificationGroups, hasLength(1));
  });

  test('⚠⚠ グループが 1 つも読めないページは、空ではなく失敗として返す', () async {
    // 空で返すと、呼び出し側は「通知が無い / ここで終わり」と読む ＝ サーバーが
    // 返している通知が黙って消える。
    final adapter = await adapterReturning({
      'accounts': [account('1')],
      'statuses': [status('100')],
      'notification_groups': [
        {'type': 'favourite', 'notifications_count': 1},
        'not a map',
      ],
    });
    await expectLater(
      adapter.client.getGroupedNotifications(),
      throwsFormatException,
    );
  });

  test('グループがもともと 0 件のページは、空のまま返す（失敗にしない）', () async {
    final adapter = await adapterReturning({
      'accounts': <Object>[],
      'statuses': <Object>[],
      'notification_groups': <Object>[],
    });
    final grouped = await adapter.client.getGroupedNotifications();
    expect(grouped.notificationGroups, isEmpty);
  });

  test('配列そのものが無い / 配列でない応答でも落ちない', () async {
    final adapter = await adapterReturning({
      'accounts': null,
      'notification_groups': 'oops',
    });
    final grouped = await adapter.client.getGroupedNotifications();
    expect(grouped.accounts, isEmpty);
    expect(grouped.statuses, isEmpty);
    expect(grouped.notificationGroups, isEmpty);
  });
}

import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_backends/src/mastodon/extensions.dart';
import 'package:capsicum_backends/src/misskey/extensions.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1042 / #1048: 通知の絞り込みとグループ化が**サーバー側**に載ることを固定する。
///
/// ⚠ クライアント側で捨てる実装に戻ると「絞り込むほど 1 ページの残りが減り、
/// もっと読むを連打させる」逆転が起きる（#993 の指摘）。ここでは実際に飛んだ
/// リクエストを見て、パラメータが載っていることを確かめる。
class _Recorder implements HttpClientAdapter {
  _Recorder(this.body, {this.statusFor});

  final Object body;

  /// path の一部 -> 返すステータス。一致しなければ 200。
  final Map<String, int>? statusFor;

  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    var status = 200;
    for (final entry in statusFor?.entries ?? const <MapEntry<String, int>>[]) {
      if (options.path.contains(entry.key)) status = entry.value;
    }
    return ResponseBody.fromString(
      status == 200 ? jsonEncode(body) : '{"error":"not found"}',
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// `uri.query` は `exclude_types%5B%5D=...` のように percent encode されるので
/// 生の文字列で比較しない。パラメータ名ごとに値を集める。
List<String> _queryValues(RequestOptions options, String name) =>
    options.uri.queryParametersAll[name] ?? const [];

void main() {
  group('Mastodon', () {
    test('種別を外すと exclude_types[] に載り、supported_types[] も付く', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final recorder = _Recorder(<Map<String, dynamic>>[]);
      adapter.client.dio.httpClientAdapter = recorder;

      await adapter.getNotifications(
        filter: const NotificationQuery(
          excludeTypes: {NotificationType.favourite, NotificationType.follow},
        ),
      );

      final request = recorder.requests.single;
      expect(request.path, contains('/api/v1/notifications'));
      expect(
        _queryValues(request, 'exclude_types[]'),
        unorderedEquals(['favourite', 'follow']),
      );
      expect(
        _queryValues(request, 'supported_types[]'),
        contains('mention'),
        reason: '⚠ 送らないと fallback は永久に来ない（needs_fallback? が即 false）',
      );
    });

    test('filter を渡さなければ絞り込みパラメータは付かない（未読数の意味を変えない）', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final recorder = _Recorder(<Map<String, dynamic>>[]);
      adapter.client.dio.httpClientAdapter = recorder;

      await adapter.getNotifications();

      final request = recorder.requests.single;
      expect(_queryValues(request, 'exclude_types[]'), isEmpty);
    });

    test('grouped なら v2 を叩く', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final recorder = _Recorder(<String, dynamic>{
        'accounts': <Map<String, dynamic>>[],
        'statuses': <Map<String, dynamic>>[],
        'notification_groups': <Map<String, dynamic>>[],
      });
      adapter.client.dio.httpClientAdapter = recorder;

      final response = await adapter.getNotifications(
        filter: const NotificationQuery(grouped: true),
      );

      expect(recorder.requests.single.path, contains('/api/v2/notifications'));
      expect(response.hasMore, isFalse, reason: '空のページまで来たらそこで打ち切る');
    });

    test('⚠ グループが limit 未満でも続きがありうる（件数で判定しない）', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final recorder = _Recorder(<String, dynamic>{
        'accounts': <Map<String, dynamic>>[],
        'statuses': <Map<String, dynamic>>[],
        'notification_groups': [
          {
            'group_key': 'favourite-1',
            'notifications_count': 20,
            'type': 'favourite',
            'most_recent_notification_id': '9020',
            'page_min_id': '9001',
            'latest_page_notification_at': '2026-09-27T00:00:00.000Z',
            'sample_account_ids': <String>[],
          },
        ],
      });
      adapter.client.dio.httpClientAdapter = recorder;

      final response = await adapter.getNotifications(
        query: const TimelineQuery(limit: 20),
        filter: const NotificationQuery(grouped: true),
      );

      expect(response.notifications, hasLength(1));
      expect(
        response.hasMore,
        isTrue,
        reason: '20 件のリアクションが 1 グループに畳まれただけで、続きはある',
      );
      expect(
        response.rawLastId,
        '9001',
        reason: '⚠ カーソルは page_min_id。most_recent なら末尾のグループの古いぶんを飛ばす',
      );
    });

    test('⚠ v2 が無いサーバーでは v1 へ落とす（通知が丸ごと消えない）', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final recorder = _Recorder(
        <Map<String, dynamic>>[],
        statusFor: {'/api/v2/notifications': 404},
      );
      adapter.client.dio.httpClientAdapter = recorder;

      final response = await adapter.getNotifications(
        filter: const NotificationQuery(grouped: true),
      );

      expect(response.notifications, isEmpty);
      expect(recorder.requests.map((r) => r.path), [
        '/api/v2/notifications',
        '/api/v1/notifications',
      ]);

      // ⚠ 2 ページ目以降は v2 を叩き直さない。
      recorder.requests.clear();
      await adapter.getNotifications(
        filter: const NotificationQuery(grouped: true),
      );
      expect(recorder.requests.map((r) => r.path), ['/api/v1/notifications']);
    });

    test('⚠ 401 / 429 は「v2 が無い」と読まない（一度の失敗で無効化しない）', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final recorder = _Recorder(
        <Map<String, dynamic>>[],
        statusFor: {'/api/v2/notifications': 401},
      );
      adapter.client.dio.httpClientAdapter = recorder;

      await expectLater(
        adapter.getNotifications(
          filter: const NotificationQuery(grouped: true),
        ),
        throwsA(isA<DioException>()),
      );
    });

    test('送信名は型マップから導出する（表を二重に持たない）', () {
      expect(mastodonNotificationWireNames(NotificationType.favourite), {
        'favourite',
      });
      expect(mastodonNotificationWireNames(NotificationType.followRequest), {
        'follow_request',
      });
      expect(
        mastodonNotificationWireNames(NotificationType.other),
        isEmpty,
        reason: '⚠ other はサーバー側の名前を列挙できないので除外指定が効かない',
      );
      expect(
        mastodonNotificationWireNames(NotificationType.reaction),
        isEmpty,
        reason: 'Mastodon に等価物が無い種別',
      );
      expect(
        mastodonFilterableNotificationTypes,
        isNot(contains(NotificationType.other)),
      );
      expect(
        mastodonFilterableNotificationTypes,
        contains(NotificationType.mention),
      );
      expect(mastodonSupportedNotificationTypes, contains('mention'));
    });
  });

  group('Misskey', () {
    test('種別を外すと excludeTypes に載る（POST body）', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final recorder = _Recorder(<Map<String, dynamic>>[]);
      adapter.client.dio.httpClientAdapter = recorder;

      await adapter.getNotifications(
        filter: const NotificationQuery(
          excludeTypes: {NotificationType.mention},
        ),
      );

      final request = recorder.requests.single;
      expect(request.path, contains('/api/i/notifications'));
      final body = request.data as Map<String, dynamic>;
      expect(
        body['excludeTypes'],
        unorderedEquals(['mention', 'reply']),
        reason: '⚠ 表が両方を mention に寄せているので、外すときも両方外す',
      );
      expect(
        body['markAsRead'],
        isFalse,
        reason: '⚠ 既定 true のまま送ると取得だけでサーバーの未読が消える (#1045)',
      );
    });

    test('grouped なら notifications-grouped を叩く', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final recorder = _Recorder(<Map<String, dynamic>>[]);
      adapter.client.dio.httpClientAdapter = recorder;

      await adapter.getNotifications(
        filter: const NotificationQuery(grouped: true),
      );

      expect(recorder.requests.single.path, '/api/i/notifications-grouped');
    });

    test('⚠ grouped が無いサーバーでは通常の一覧へ落とす', () async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final recorder = _Recorder(
        <Map<String, dynamic>>[],
        statusFor: {'notifications-grouped': 404},
      );
      adapter.client.dio.httpClientAdapter = recorder;

      await adapter.getNotifications(
        filter: const NotificationQuery(grouped: true),
      );

      expect(recorder.requests.map((r) => r.path), [
        '/api/i/notifications-grouped',
        '/api/i/notifications',
      ]);
    });

    test('送信名は型マップから導出する', () {
      expect(misskeyNotificationWireNames(NotificationType.reblog), {'renote'});
      expect(misskeyNotificationWireNames(NotificationType.mention), {
        'mention',
        'reply',
      });
      expect(
        misskeyNotificationWireNames(NotificationType.favourite),
        isEmpty,
        reason: 'Misskey にお気に入り通知は無い',
      );
      expect(
        misskeyFilterableNotificationTypes,
        isNot(contains(NotificationType.other)),
      );
      expect(
        misskeyFilterableNotificationTypes,
        contains(NotificationType.reaction),
      );
    });
  });
}

import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_backends/src/misskey/extensions.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1212: 予約投稿の時刻を変える。
///
/// ここで固定するのは**送信するリクエストの形**。どちらの SNS も、余計な項目を
/// 送ると予約投稿の中身を壊す側に倒れる（Misskey は送った項目で上書きする）。
class _Recorder implements HttpClientAdapter {
  _Recorder(this.respond);

  final Object Function(RequestOptions options) respond;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(respond(options)),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _body(RequestOptions options) =>
    options.data as Map<String, dynamic>;

void main() {
  final newTime = DateTime.utc(2026, 12, 24, 9, 30);

  group('Mastodon', () {
    test('PUT scheduled_statuses/:id に scheduled_at だけを送る', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final http = _Recorder((_) => <String, dynamic>{});
      adapter.client.dio.httpClientAdapter = http;

      await (adapter as ScheduleSupport).rescheduleScheduledPost('42', newTime);

      final request = http.requests.single;
      expect(request.method, 'PUT');
      expect(request.path, '/api/v1/scheduled_statuses/42');
      expect(_body(request), {'scheduled_at': '2026-12-24T09:30:00.000Z'});
    });

    test('⚠ 端末の時刻（ローカル）で渡しても、UTC にして送る', () async {
      final adapter = await MastodonAdapter.create('example.com');
      final http = _Recorder((_) => <String, dynamic>{});
      adapter.client.dio.httpClientAdapter = http;

      await (adapter as ScheduleSupport).rescheduleScheduledPost(
        '42',
        newTime.toLocal(),
      );

      expect(
        _body(http.requests.single)['scheduled_at'],
        '2026-12-24T09:30:00.000Z',
      );
    });
  });

  group('Misskey', () {
    late MisskeyAdapter adapter;
    late _Recorder http;
    late List<Map<String, dynamic>> drafts;

    setUp(() async {
      adapter = await MisskeyAdapter.create('misskey.example');
      drafts = [
        {'id': 'd1', 'text': 'こんにちは', 'scheduledAt': 1, 'poll': null},
      ];
      http = _Recorder(
        (options) =>
            options.path.contains('drafts/list') ? drafts : <String, dynamic>{},
      );
      adapter.client.dio.httpClientAdapter = http;
    });

    RequestOptions update() =>
        http.requests.singleWhere((r) => r.path.contains('drafts/update'));

    test('⚠⚠ 時刻だけを送る（本文・添付を送らない＝サーバーの値のまま）', () async {
      await (adapter as ScheduleSupport).rescheduleScheduledPost('d1', newTime);

      final body = _body(update());
      expect(body['draftId'], 'd1');
      expect(body['scheduledAt'], newTime.millisecondsSinceEpoch);
      expect(body['isActuallyScheduled'], isTrue);
      for (final key in ['text', 'fileIds', 'cw', 'visibility', 'poll']) {
        expect(body.containsKey(key), isFalse, reason: '$key を送ると上書きする');
      }
    });

    // 上流のエンドポイントは、poll の無い要求でも pollExpiresAt を null で
    // 上書きする。送り直さないと、投票の期限が消える。
    test('⚠⚠ 投票つきは、投票を送り直す（送らないと期限が消える）', () async {
      drafts = [
        {
          'id': 'd1',
          'text': 'どっち？',
          'scheduledAt': 1,
          'poll': {
            'choices': ['A', 'B'],
            'multiple': true,
            'expiresAt': '2026-12-31T00:00:00.000Z',
            'expiredAfter': null,
          },
        },
      ];

      await (adapter as ScheduleSupport).rescheduleScheduledPost('d1', newTime);

      expect(_body(update())['poll'], {
        'choices': ['A', 'B'],
        'multiple': true,
        'expiresAt': DateTime.utc(2026, 12, 31).millisecondsSinceEpoch,
      });
    });

    // #1293: 以前は limit を付けず、上流の既定（30 件）で切れていた。
    test('⚠⚠ 予約が 100 件を超えても、全件を辿って投票を送り直す', () async {
      final all = [
        for (var i = 0; i < 101; i++)
          {
            'id': 'd${1000 - i}',
            'text': '予約 $i',
            'scheduledAt': 1,
            'poll': i == 100
                ? {
                    'choices': ['A', 'B'],
                    'multiple': false,
                    'expiresAt': '2026-12-31T00:00:00.000Z',
                    'expiredAfter': null,
                  }
                : null,
          },
      ];
      http = _Recorder((options) {
        if (!options.path.contains('drafts/list')) return <String, dynamic>{};
        final body = _body(options);
        final untilId = body['untilId'] as String?;
        final start = untilId == null
            ? 0
            : all.indexWhere((d) => d['id'] == untilId) + 1;
        return all.skip(start).take(body['limit'] as int).toList();
      });
      adapter.client.dio.httpClientAdapter = http;

      await (adapter as ScheduleSupport).rescheduleScheduledPost(
        'd900',
        newTime,
      );

      final lists = http.requests.where((r) => r.path.contains('drafts/list'));
      expect(lists.length, 2, reason: '100 件のページを辿って 101 件目まで引く');
      expect(_body(update())['poll'], isNotNull, reason: '101 件目の投票を送り直す');
    });

    test('⚠⚠ サーバーが同じページを返し続けても、辿るのをやめる (#1304)', () async {
      // untilId を無視して、毎回同じ 100 件を返すサーバー。以前は while (true)
      // で終わらなかった。
      final page = [
        for (var i = 0; i < 100; i++)
          {'id': 'd$i', 'text': '予約 $i', 'scheduledAt': 1, 'poll': null},
      ];
      http = _Recorder(
        (options) =>
            options.path.contains('drafts/list') ? page : <String, dynamic>{},
      );
      adapter.client.dio.httpClientAdapter = http;

      final all = await adapter.client.getScheduledNotesRaw();

      final lists = http.requests.where((r) => r.path.contains('drafts/list'));
      expect(lists.length, 2, reason: '2 ページ目で進んでいないと分かったら止める');
      expect(all, hasLength(200));
    });

    test('⚠ 進み続けるサーバーでも、決めたページ数で打ち切る (#1304)', () async {
      var n = 0;
      http = _Recorder((options) {
        if (!options.path.contains('drafts/list')) return <String, dynamic>{};
        return [
          for (var i = 0; i < 100; i++)
            {'id': 'd${n++}', 'scheduledAt': 1, 'poll': null},
        ];
      });
      adapter.client.dio.httpClientAdapter = http;

      await adapter.client.getScheduledNotesRaw(maxPages: 3);

      final lists = http.requests.where((r) => r.path.contains('drafts/list'));
      expect(lists.length, 3);
    });

    test('本文を変える回（タグ編集）も同じ口を通り、投票を送り直す', () async {
      drafts = [
        {
          'id': 'd1',
          'text': 'どっち？',
          'scheduledAt': 1,
          'poll': {
            'choices': ['A', 'B'],
            'multiple': false,
            'expiresAt': null,
            'expiredAfter': 3600000,
          },
        },
      ];

      await adapter.updateScheduledNote(
        id: 'd1',
        text: 'どっち？\n\n#tag',
        scheduledAt: newTime,
      );

      final body = _body(update());
      expect(body['text'], 'どっち？\n\n#tag');
      expect(body['poll'], {
        'choices': ['A', 'B'],
        'multiple': false,
        'expiredAfter': 3600000,
      });
    });

    test('⚠ 下書きを引けなかったら更新しない（投票の期限を消す側に倒さない）', () async {
      adapter.client.dio.httpClientAdapter = _FailingList(http);

      await expectLater(
        (adapter as ScheduleSupport).rescheduleScheduledPost('d1', newTime),
        throwsA(isA<DioException>()),
      );
      expect(
        http.requests.where((r) => r.path.contains('drafts/update')),
        isEmpty,
      );
    });
  });

  group('misskeyDraftPollParams', () {
    test('投票が無ければ null', () {
      expect(misskeyDraftPollParams({'id': 'd1'}), isNull);
      expect(misskeyDraftPollParams({'id': 'd1', 'poll': null}), isNull);
    });

    test('⚠ 選択肢が空の投票は送らない（送ると中身を消す）', () {
      expect(
        misskeyDraftPollParams({
          'poll': {'choices': <String>[], 'multiple': false},
        }),
        isNull,
      );
    });

    test('⚠ expiresAt は ISO 文字列で返り、epoch ミリ秒で送る', () {
      final params = misskeyDraftPollParams({
        'poll': {
          'choices': ['A', 'B'],
          'multiple': false,
          'expiresAt': '2026-12-31T00:00:00.000Z',
        },
      });
      expect(
        params!['expiresAt'],
        DateTime.utc(2026, 12, 31).millisecondsSinceEpoch,
      );
      expect(params.containsKey('expiredAfter'), isFalse);
    });
  });
}

/// 一覧の取得だけを落とす。
class _FailingList implements HttpClientAdapter {
  _FailingList(this.inner);

  final _Recorder inner;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) {
    if (options.path.contains('drafts/list')) {
      return Future.value(ResponseBody.fromString('{}', 500));
    }
    return inner.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

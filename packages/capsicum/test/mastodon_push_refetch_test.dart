import 'dart:convert';
import 'dart:typed_data';

import 'package:capsicum/src/service/mastodon_push_refetch.dart';
import 'package:capsicum_core/capsicum_core.dart' show PushAlertCategory;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// #1426: 上流に古い購読が残っていて、古い鍵の 1 通が届いたときの引き直し。

final _now = DateTime.utc(2026, 11, 25, 12, 0, 0);

Map<String, dynamic> _mention({
  String id = '100',
  DateTime? createdAt,
  String content = '<p>こんにちは<br>また明日</p>',
  String spoiler = '',
}) => {
  'id': id,
  'type': 'mention',
  'created_at': (createdAt ?? _now.subtract(const Duration(seconds: 5)))
      .toIso8601String(),
  'account': {'acct': 'alice@example.com', 'display_name': 'アリス'},
  'status': {'content': content, 'spoiler_text': spoiler},
};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    MastodonPushRefetch.dioFactory = Dio.new;
    MastodonPushRefetch.tokenReader = (_) async => null;
    MastodonPushRefetch.mutedReader = (_) async => const {};
  });

  group('受け取らない分類（#1411）', () {
    test('切った種類は exclude_types[] で除いて引く', () async {
      final adapter = _Adapter(200, jsonEncode([_mention()]));
      MastodonPushRefetch.dioFactory = () => Dio()..httpClientAdapter = adapter;
      MastodonPushRefetch.tokenReader = (_) async => 'tok';
      String? readKey;
      MastodonPushRefetch.mutedReader = (key) async {
        readKey = key;
        return {PushAlertCategory.favourite, PushAlertCategory.follow};
      };

      final result = await MastodonPushRefetch.fetchLatest(
        'konchie@fedibird.com',
        now: () => _now,
      );
      expect(readKey, 'mastodon://konchie@fedibird.com');
      expect(adapter.lastUri!.queryParametersAll['exclude_types[]'], [
        'favourite',
        'follow',
        'follow_request',
      ]);
      expect(result, isNotNull);
    });

    test('除かずに返すサーバーでも、切った種類は出さない', () async {
      final favourite = {..._mention(), 'type': 'favourite'};
      final adapter = _Adapter(200, jsonEncode([favourite]));
      MastodonPushRefetch.dioFactory = () => Dio()..httpClientAdapter = adapter;
      MastodonPushRefetch.tokenReader = (_) async => 'tok';
      MastodonPushRefetch.mutedReader = (_) async => {
        PushAlertCategory.favourite,
      };

      final result = await MastodonPushRefetch.fetchLatest(
        'konchie@fedibird.com',
        now: () => _now,
      );
      expect(result, isNull);
    });

    test('何も切っていなければ exclude_types[] を付けない', () async {
      final adapter = _Adapter(200, jsonEncode([_mention()]));
      MastodonPushRefetch.dioFactory = () => Dio()..httpClientAdapter = adapter;
      MastodonPushRefetch.tokenReader = (_) async => 'tok';

      await MastodonPushRefetch.fetchLatest(
        'konchie@fedibird.com',
        now: () => _now,
      );
      expect(
        adapter.lastUri!.queryParametersAll.containsKey('exclude_types[]'),
        isFalse,
      );
    });
  });

  test('引けなかった種類は onFailure に渡す（記録は呼び出し側）', () async {
    MastodonPushRefetch.tokenReader = (_) async => 'tok';
    final kinds = <String>[];
    for (final adapter in [
      _Adapter(401, '{"error":"x"}'),
      _Adapter(200, '{"not":"a list"}'),
    ]) {
      MastodonPushRefetch.dioFactory = () => Dio()..httpClientAdapter = adapter;
      await MastodonPushRefetch.fetchLatest(
        'konchie@fedibird.com',
        now: () => _now,
        onFailure: kinds.add,
      );
    }
    expect(kinds, ['http_401', 'parse']);
  });

  group('contentFromNotification', () {
    test('投稿のある通知は本文を平文にする', () {
      final content = MastodonPushRefetch.contentFromNotification(_mention());
      expect(content.type, 'mention');
      expect(content.body, 'こんにちは\nまた明日');
      expect(content.notificationId, '100');
      // 見出しは呼び出し側が type から作る。
      expect(content.title, isNull);
    });

    test('CW があれば CW の見出しだけを出し、本文は出さない', () {
      final content = MastodonPushRefetch.contentFromNotification(
        _mention(spoiler: 'ネタバレ', content: '<p>犯人は</p>'),
      );
      expect(content.body, 'ネタバレ');
    });

    test('投稿の無い通知は相手の表示名、空なら @acct', () {
      final follow = MastodonPushRefetch.contentFromNotification({
        'id': '1',
        'type': 'follow',
        'account': {'acct': 'bob', 'display_name': 'ボブ'},
      });
      expect(follow.body, 'ボブ');

      final noName = MastodonPushRefetch.contentFromNotification({
        'id': '2',
        'type': 'follow',
        'account': {'acct': 'bob', 'display_name': '  '},
      });
      expect(noName.body, '@bob');
    });
  });

  group('isFresh', () {
    test('60 秒以内なら採る・過ぎたら採らない', () {
      expect(
        MastodonPushRefetch.isFresh(
          _mention(createdAt: _now.subtract(const Duration(seconds: 60))),
          _now,
        ),
        isTrue,
      );
      expect(
        MastodonPushRefetch.isFresh(
          _mention(createdAt: _now.subtract(const Duration(seconds: 61))),
          _now,
        ),
        isFalse,
      );
    });

    test('日時が読めなければ採らない', () {
      expect(MastodonPushRefetch.isFresh({'created_at': 'きのう'}, _now), isFalse);
      expect(MastodonPushRefetch.isFresh({}, _now), isFalse);
    });
  });

  group('accept', () {
    test('同じ通知は二度出さない', () async {
      final first = await MastodonPushRefetch.accept(
        _mention(),
        account: 'konchie@fedibird.com',
        now: _now,
      );
      final second = await MastodonPushRefetch.accept(
        _mention(),
        account: 'konchie@fedibird.com',
        now: _now,
      );
      expect(first, isNotNull);
      expect(second, isNull);
    });

    test('復号できて出した通知（noteShown 済み）は引き直しで出さない', () async {
      await MastodonPushRefetch.noteShown('100', 'konchie@fedibird.com');
      final result = await MastodonPushRefetch.accept(
        _mention(),
        account: 'konchie@fedibird.com',
        now: _now,
      );
      expect(result, isNull);
    });

    test('控えはアカウントごと', () async {
      await MastodonPushRefetch.noteShown('100', 'konchie@pawoo.net');
      final result = await MastodonPushRefetch.accept(
        _mention(),
        account: 'konchie@fedibird.com',
        now: _now,
      );
      expect(result, isNotNull);
    });

    test('控えは直近 8 件だけ残す', () async {
      for (var i = 0; i < 10; i++) {
        await MastodonPushRefetch.noteShown('$i', 'a@example.com');
      }
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('capsicum_push_shown_ids_a@example.com'), [
        '2',
        '3',
        '4',
        '5',
        '6',
        '7',
        '8',
        '9',
      ]);
    });
  });

  group('fetchLatest', () {
    test('Mastodon 系のトークンが無ければ API を叩かない', () async {
      final adapter = _Adapter(200, '[]');
      MastodonPushRefetch.dioFactory = () => Dio()..httpClientAdapter = adapter;
      MastodonPushRefetch.tokenReader = (_) async => null;

      final result = await MastodonPushRefetch.fetchLatest(
        'someone@misskey.example',
        now: () => _now,
      );
      expect(result, isNull);
      expect(adapter.calls, 0);
    });

    test('最新の 1 件を Bearer で引き、中身を返す', () async {
      final adapter = _Adapter(200, jsonEncode([_mention()]));
      MastodonPushRefetch.dioFactory = () => Dio()..httpClientAdapter = adapter;
      String? readKey;
      MastodonPushRefetch.tokenReader = (key) async {
        readKey = key;
        return 'tok';
      };

      final result = await MastodonPushRefetch.fetchLatest(
        'konchie@fedibird.com',
        now: () => _now,
      );
      expect(readKey, 'mastodon://konchie@fedibird.com');
      expect(
        adapter.lastUri.toString(),
        'https://fedibird.com/api/v1/notifications?limit=1',
      );
      expect(adapter.lastAuth, 'Bearer tok');
      expect(result?.body, 'こんにちは\nまた明日');
    });

    test('HTTP の失敗・0 件・古い通知では null', () async {
      MastodonPushRefetch.tokenReader = (_) async => 'tok';
      for (final adapter in [
        _Adapter(401, '{"error":"x"}'),
        _Adapter(200, '[]'),
        _Adapter(
          200,
          jsonEncode([
            _mention(createdAt: _now.subtract(const Duration(minutes: 5))),
          ]),
        ),
      ]) {
        MastodonPushRefetch.dioFactory = () =>
            Dio()..httpClientAdapter = adapter;
        final result = await MastodonPushRefetch.fetchLatest(
          'konchie@fedibird.com',
          now: () => _now,
        );
        expect(result, isNull);
      }
    });
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.status, this.body);

  final int status;
  final String body;
  int calls = 0;
  Uri? lastUri;
  String? lastAuth;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    lastUri = options.uri;
    lastAuth = options.headers['Authorization'] as String?;
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

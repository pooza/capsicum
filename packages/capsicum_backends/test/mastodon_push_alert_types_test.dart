import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// 要求の path と FormData のフィールドを控えるだけの adapter。
class _CapturingAdapter implements HttpClientAdapter {
  String? lastPath;
  Map<String, String> fields = {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastPath = options.path;
    final data = options.data;
    if (data is FormData) {
      fields = {for (final e in data.fields) e.key: e.value};
    }
    return ResponseBody.fromString(
      jsonEncode({'id': 1}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('pushAlertTypes (#1204)', () {
    // Mastodon 4.7.3 の `Notification::PROPERTIES` のキー全部。
    // `pooza/mastodon` の app/models/notification.rb から写した（2026-10-03）。
    //
    // ⚠⚠ **この表を「capsicum が送っているもの」から作らないこと。**それでは
    // 実装を実装で確かめることになり、抜けていても緑になる（#1204 がまさに
    // 「7 種しか送っていないのに誰も気付かなかった」形）。**上流の定義が母数。**
    const upstreamTypes = <String>{
      'mention',
      'status',
      'reblog',
      'follow',
      'follow_request',
      'favourite',
      'poll',
      'update',
      'severed_relationships',
      'moderation_warning',
      'annual_report',
      'admin.sign_up',
      'admin.report',
      'quote',
      'quoted_update',
      'added_to_collection',
      'collection_update',
    };

    test('上流の全 17 種を網羅している', () {
      expect(pushAlertTypes.toSet(), upstreamTypes);
      expect(pushAlertTypes, hasLength(17));
    });

    test('⚠ #1204 で足した 10 種が入っている（起票時に抜けていたぶん）', () {
      // 🔴 実害が出ていた 4 種を名前で固定する。⚠ 件数だけ見ると、別の種別が
      // 増えて 17 になっただけでも通ってしまう。
      expect(pushAlertTypes, contains('moderation_warning'));
      expect(pushAlertTypes, contains('admin.report'));
      expect(pushAlertTypes, contains('quote'));
      expect(pushAlertTypes, contains('follow_request'));
      // 残り 6 種。
      expect(pushAlertTypes, contains('severed_relationships'));
      expect(pushAlertTypes, contains('annual_report'));
      expect(pushAlertTypes, contains('admin.sign_up'));
      expect(pushAlertTypes, contains('quoted_update'));
      expect(pushAlertTypes, contains('added_to_collection'));
      expect(pushAlertTypes, contains('collection_update'));
    });

    test('重複が無い', () {
      expect(pushAlertTypes.toSet(), hasLength(pushAlertTypes.length));
    });
  });

  group('MastodonClient.subscribePush (#1204)', () {
    test('全種別を data[alerts][…]=true として送る', () async {
      final adapter = await MastodonAdapter.create('mastodon.example');
      final capture = _CapturingAdapter();
      adapter.client.dio.httpClientAdapter = capture;

      await adapter.subscribePush(
        endpoint: 'https://relay.example/push/abc',
        p256dh: 'p256dh-dummy',
        auth: 'auth-dummy',
      );

      expect(capture.lastPath, '/api/v1/push/subscription');

      // ⚠ 送った alerts のキーを payload から抜き直して突き合わせる（定数を
      // そのまま比べると、ループが壊れていても通る）。
      final sentAlerts = capture.fields.keys
          .where((k) => k.startsWith('data[alerts]['))
          .map((k) => k.substring('data[alerts]['.length, k.length - 1))
          .toSet();
      expect(sentAlerts, pushAlertTypes.toSet());
      for (final type in pushAlertTypes) {
        expect(capture.fields['data[alerts][$type]'], 'true');
      }
    });

    test('⚠ subscription[standard] は true のまま（aes128gcm を選ぶ・#336）', () async {
      // #1204 でこの行の隣を触るので、一緒に固定しておく。落とすと Mastodon が
      // legacy aesgcm へフォールバックする。⚠ aesgcm も #1390（Akkoma）から
      // 復号できるようになったが、本文が長くなり（ヘッダ 2 本ぶん）APNs の 4KB で
      // 縮退しやすくなるので、Mastodon には引き続き aes128gcm を選ばせる。
      final adapter = await MastodonAdapter.create('mastodon.example');
      final capture = _CapturingAdapter();
      adapter.client.dio.httpClientAdapter = capture;

      await adapter.subscribePush(
        endpoint: 'https://relay.example/push/abc',
        p256dh: 'p256dh-dummy',
        auth: 'auth-dummy',
      );

      expect(capture.fields['subscription[standard]'], 'true');
      expect(
        capture.fields['subscription[endpoint]'],
        'https://relay.example/push/abc',
      );
      expect(capture.fields['subscription[keys][p256dh]'], 'p256dh-dummy');
      expect(capture.fields['subscription[keys][auth]'], 'auth-dummy');
    });

    test('⚠ data[policy] は送らない（サーバー既定の all に任せる）', () async {
      final adapter = await MastodonAdapter.create('mastodon.example');
      final capture = _CapturingAdapter();
      adapter.client.dio.httpClientAdapter = capture;

      await adapter.subscribePush(
        endpoint: 'https://relay.example/push/abc',
        p256dh: 'p256dh-dummy',
        auth: 'auth-dummy',
      );

      expect(capture.fields.containsKey('data[policy]'), isFalse);
    });
  });

  // #1411: 通知の種類ごとにプッシュ通知をオン / オフする。
  group('通知の分類で絞る (#1411)', () {
    test('⚠⚠ 分類が指す種別は、すべて送っている種別に含まれる', () {
      // 表に無い種別を絞っても、購読の本文に載らないので効かない。
      for (final types in mastodonAlertTypesByCategory.values) {
        for (final type in types) {
          expect(pushAlertTypes, contains(type));
        }
      }
    });

    test('すべての分類に行き先がある', () {
      expect(
        mastodonAlertTypesByCategory.keys.toSet(),
        PushAlertCategory.values.toSet(),
      );
    });

    test('⚠ 分類に入らない種別（警告・通報など）は絞れない', () {
      final filterable = mastodonMutedAlertTypes(
        PushAlertCategory.values.toSet(),
      );
      expect(filterable, isNot(contains('moderation_warning')));
      expect(filterable, isNot(contains('admin.report')));
      expect(filterable, isNot(contains('severed_relationships')));
    });

    test('切った分類だけ false で送り、ほかは true のまま', () async {
      final adapter = await MastodonAdapter.create('mastodon.example');
      final capture = _CapturingAdapter();
      adapter.client.dio.httpClientAdapter = capture;

      await adapter.subscribePush(
        endpoint: 'https://relay.example/push/abc',
        p256dh: 'p256dh-dummy',
        auth: 'auth-dummy',
        mutedCategories: {
          PushAlertCategory.favourite,
          PushAlertCategory.follow,
        },
      );

      expect(capture.fields['data[alerts][favourite]'], 'false');
      expect(capture.fields['data[alerts][follow]'], 'false');
      expect(capture.fields['data[alerts][follow_request]'], 'false');
      expect(capture.fields['data[alerts][mention]'], 'true');
      expect(capture.fields['data[alerts][reblog]'], 'true');
      expect(capture.fields['data[alerts][moderation_warning]'], 'true');
    });

    test('Mastodon は絞れる・Misskey は絞れない', () async {
      expect(
        (await MastodonAdapter.create('m.example')).supportsPushAlertFilter,
        isTrue,
      );
      expect(
        (await MisskeyAdapter.create('k.example')).supportsPushAlertFilter,
        isFalse,
      );
    });
  });
}

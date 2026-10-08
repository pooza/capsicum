import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
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
      // legacy aesgcm へフォールバックし、relay がヘッダを転送しないため
      // クライアント側で復号できなくなる。
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
}

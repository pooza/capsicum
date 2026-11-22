// #1408: アカウントごとにプッシュ通知をオン / オフする。
//
// ⚠⚠ オフにしても relay の行は消さない（案 A・2026-11-22 pooza）。relay は
// 「同じ端末にプリセットの行があるか」で無償の特例を決める（relay#82）ので、
// プリセットのアカウントをオフにしたとき行まで作らないと、端末のトークンが
// 変わった回の掃除のあとで外部のアカウントが有償側に倒れる。
import 'dart:io';

import 'package:capsicum/src/service/push_disabled_accounts.dart';
import 'package:capsicum/src/service/push_registration_status.dart';
import 'package:capsicum/src/ui/widget/push_registration_status_section.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dart_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PushDisabledAccounts', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      initSharedPreferencesCache(await SharedPreferences.getInstance());
    });
    tearDown(() => debugSetSharedPreferencesCache(null));

    test('既定はオン（何も保存していない）', () {
      expect(
        PushDisabledAccounts.isDisabled('mastodon://a@x.example'),
        isFalse,
      );
    });

    test('オフにしたアカウントだけがオフになる', () async {
      await PushDisabledAccounts.setDisabled('mastodon://a@x.example', true);

      expect(PushDisabledAccounts.isDisabled('mastodon://a@x.example'), isTrue);
      expect(PushDisabledAccounts.isDisabled('misskey://b@y.example'), isFalse);
    });

    test('オンに戻すと消え、空になったらキーごと消す', () async {
      await PushDisabledAccounts.setDisabled('mastodon://a@x.example', true);
      await PushDisabledAccounts.setDisabled('mastodon://a@x.example', false);

      expect(
        PushDisabledAccounts.isDisabled('mastodon://a@x.example'),
        isFalse,
      );
      expect(
        sharedPrefsOrThrow.containsKey(PushDisabledAccounts.prefsKey),
        isFalse,
      );
    });

    test('⚠ 読めなければオン扱い（黙って通知を止めない）', () {
      debugSetSharedPreferencesCache(null);
      expect(
        PushDisabledAccounts.isDisabled('mastodon://a@x.example'),
        isFalse,
      );
    });
  });

  group('登録状況の表示', () {
    test('「オフ」と出し、再試行は出さない（失敗ではない）', () {
      final (text, _, _) = describePushRegistrationStatus(
        ThemeData(),
        PushRegistrationState.disabledByUser,
        true,
        null,
      );
      expect(text, 'オフ');
      expect(
        isPushRegistrationRetryable(
          PushRegistrationState.disabledByUser,
          eligible: true,
        ),
        isFalse,
      );
    });
  });

  // ⚠⚠ 登録の処理の中で、オフの判定は「relay への登録と記録のあと、SNS 側の
  // 購読の前」に置く。relay の登録より前で止めると、プリセットの行が relay から
  // 消えたまま戻らない。
  group('登録の処理の中の順番', () {
    test('実物', () {
      final source = File(
        'lib/src/service/push_registration_service.dart',
      ).readAsStringSync();
      expect(
        source,
        contains('static Future<void> _registerAccountImpl('),
        reason: '前提: 登録の本体がある',
      );
      expect(registrationOrderViolation(source), isNull);
    });

    // ⚠ 判定は合成ソースでも確かめる（docs/CLAUDE.md「ソース検査ガードの書き方」）。
    test('判定（合成ソース）', () {
      String impl(List<String> lines) =>
          'static Future<void> _registerAccountImpl(\n'
          '${lines.join('\n')}\n  }\n';
      const relay = 'await _client.register(';
      const saveId = 'await PushKeyStore.saveRelayId(';
      const saveToken = 'await PushKeyStore.saveDeviceToken(';
      const gate = 'if (PushDisabledAccounts.isDisabled(accountKey)) return;';
      const keys = 'await PushKeyStore.getOrCreate(';
      const subscribe = 'await adapter.subscribePush(';
      expect(
        registrationOrderViolation(
          impl([relay, saveId, saveToken, gate, keys, subscribe]),
        ),
        isNull,
      );
      expect(
        registrationOrderViolation(
          impl([gate, relay, saveId, saveToken, keys, subscribe]),
        ),
        isNotNull,
        reason: 'relay の行より前で止めている',
      );
      expect(
        registrationOrderViolation(
          impl([relay, saveId, saveToken, keys, subscribe, gate]),
        ),
        isNotNull,
        reason: '購読のあとで判定している',
      );
      expect(
        registrationOrderViolation(
          impl([relay, saveId, saveToken, '// $gate', keys, subscribe]),
        ),
        isNotNull,
        reason: 'コメントの中の判定は数えない',
      );
      expect(
        registrationOrderViolation(
          impl([gate, relay, saveId, saveToken, gate, keys, subscribe]),
        ),
        isNotNull,
        reason: '判定が 2 か所ある',
      );
    });
  });
}

/// 登録の本体で、オフの判定の位置が崩れていれば、その理由。正しければ null。
///
/// 正しい順: relay への登録 → 記録（relay の ID・端末のトークン）→ オフの判定
/// → 鍵 → SNS への購読。
String? registrationOrderViolation(String source) {
  final masked = maskComments(source);
  final start = masked.indexOf('static Future<void> _registerAccountImpl(');
  if (start < 0) return '登録の本体が無い';
  final end = masked.indexOf('\n  }\n', start);
  final body = masked.substring(start, end < 0 ? masked.length : end);
  const order = [
    'await _client.register(',
    'await PushKeyStore.saveRelayId(',
    'await PushKeyStore.saveDeviceToken(',
    'PushDisabledAccounts.isDisabled(accountKey)',
    'await PushKeyStore.getOrCreate(',
    '.subscribePush(',
  ];
  if ('PushDisabledAccounts.isDisabled('.allMatches(body).length != 1) {
    return 'オフの判定が 1 か所ではない';
  }
  var last = -1;
  for (final needle in order) {
    final at = body.indexOf(needle);
    if (at < 0) return '`$needle` が無い';
    if (at < last) return '`$needle` の位置が前後している';
    last = at;
  }
  return null;
}

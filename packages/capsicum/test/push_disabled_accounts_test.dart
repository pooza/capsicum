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
    test('「オフにしています」と出し、再試行は出さない（失敗ではない）', () {
      final (text, _, _) = describePushRegistrationStatus(
        ThemeData(),
        PushRegistrationState.disabledByUser,
        true,
        null,
      );
      expect(text, 'オフにしています');
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
    late String body;

    setUpAll(() {
      final source = File(
        'lib/src/service/push_registration_service.dart',
      ).readAsStringSync();
      final start = source.indexOf('static Future<void> _registerAccountImpl(');
      expect(start, greaterThanOrEqualTo(0), reason: '前提: 登録の本体がある');
      final end = source.indexOf('\n  }\n', start);
      body = source.substring(start, end);
    });

    int at(String needle) {
      final i = body.indexOf(needle);
      expect(i, greaterThanOrEqualTo(0), reason: '前提: `$needle` がある');
      return i;
    }

    test('relay への登録 → 記録 → オフの判定 → 鍵 → SNS への購読', () {
      final relay = at('await _client.register(');
      final saveId = at('await PushKeyStore.saveRelayId(');
      final saveToken = at('await PushKeyStore.saveDeviceToken(');
      final gate = at('PushDisabledAccounts.isDisabled(accountKey)');
      final keys = at('await PushKeyStore.getOrCreate(');
      final subscribe = at('.subscribePush(');

      expect(relay, lessThan(gate), reason: 'relay の行は作る');
      expect(saveId, lessThan(gate), reason: '次の掃除で行を消せるよう記録する');
      expect(saveToken, lessThan(gate));
      expect(gate, lessThan(keys));
      expect(gate, lessThan(subscribe), reason: 'SNS 側の購読はしない');
    });

    test('オフの判定は 1 か所だけ（ほかの位置で早く止めていない）', () {
      expect('PushDisabledAccounts.isDisabled('.allMatches(body), hasLength(1));
    });
  });
}

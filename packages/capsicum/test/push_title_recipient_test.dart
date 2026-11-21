// #1407: 復号できたプッシュの見出しに、宛先のアカウントを添える。
//
// 複数のアカウントでログインしているときだけ添える（デスクトップの WebSocket
// 経路 #675 と同じ線）。判定はアプリ本体で行い、FCM のバックグラウンド isolate と
// iOS / macOS の NSE は写し（NotificationLabelCache.multiAccountKey）を読む。
import 'dart:io';

import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/model/offline_account.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/service/notification_label_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _Adapter extends Mock implements DecentralizedBackendAdapter {}

AccountKey _key(String name) => AccountKey(
  type: BackendType.mastodon,
  host: '$name.example',
  username: name,
);

Account _account(String name) => Account(
  key: _key(name),
  adapter: _Adapter(),
  user: User(id: name, username: name),
  userSecret: const UserSecret(accessToken: 'token'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('titleWithRecipient', () {
    test('複数アカウントなら `見出し (@user@host)` にする', () {
      expect(
        titleWithRecipient('お気に入り', 'alice@mstdn.example', multiAccount: true),
        'お気に入り (@alice@mstdn.example)',
      );
    });

    test('1 アカウントなら見出しのまま', () {
      expect(
        titleWithRecipient('お気に入り', 'alice@mstdn.example', multiAccount: false),
        'お気に入り',
      );
    });

    test('宛先が空なら見出しのまま', () {
      expect(titleWithRecipient('お気に入り', '', multiAccount: true), 'お気に入り');
    });

    test('デスクトップの WebSocket 経路と同じ綴り（AccountKey.handle を括弧で添える）', () {
      // DesktopNotificationDispatcher._title は `'$base (${recipient.handle})'`。
      final key = _key('alice');
      expect(
        titleWithRecipient(
          'メンション',
          '${key.username}@${key.host}',
          multiAccount: true,
        ),
        'メンション (${key.handle})',
      );
    });
  });

  group('isMultiAccountForPush', () {
    test('0 件・1 件は false', () {
      expect(isMultiAccountForPush(const AccountManagerState()), isFalse);
      expect(
        isMultiAccountForPush(
          AccountManagerState(accounts: [_account('alice')]),
        ),
        isFalse,
      );
    });

    test('2 件なら true', () {
      expect(
        isMultiAccountForPush(
          AccountManagerState(accounts: [_account('alice'), _account('bob')]),
        ),
        isTrue,
      );
    });

    test('オフライン保持中のアカウントも数える（購読は生きていて届く）', () {
      expect(
        isMultiAccountForPush(
          AccountManagerState(
            accounts: [_account('alice')],
            offlineAccounts: [OfflineAccount(key: _key('bob'))],
          ),
        ),
        isTrue,
      );
    });

    test('同じキーがオンラインとオフラインに重なっても 1 件に数える', () {
      expect(
        isMultiAccountForPush(
          AccountManagerState(
            accounts: [_account('alice')],
            offlineAccounts: [OfflineAccount(key: _key('alice'))],
          ),
        ),
        isFalse,
      );
    });
  });

  group('NotificationLabelCache の写し', () {
    setUp(() {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    test('保存が無ければ false（宛先を添えない＝従来どおり）', () async {
      expect(await NotificationLabelCache.readMultiAccount(), isFalse);
    });

    test('save → read で取り出せる', () async {
      await NotificationLabelCache.saveMultiAccount(true);
      expect(await NotificationLabelCache.readMultiAccount(), isTrue);
      await NotificationLabelCache.saveMultiAccount(false);
      expect(await NotificationLabelCache.readMultiAccount(), isFalse);
    });

    test('プラットフォームが無くても同期で投げない（呼び出し側の catchError で受けられる）', () async {
      SharedPreferencesAsyncPlatform.instance = null;
      final future = NotificationLabelCache.saveMultiAccount(true);
      await expectLater(future, throwsA(anything));
    });
  });

  // ⚠ NSE は Dart を読めないので、キーと見出しの形を Swift 側に写している。
  // 片方だけ変えると、iOS だけ宛先が付かない / 形がずれる。
  group('NSE との一致', () {
    const nseFiles = [
      'ios/CapsicumNotificationService/NotificationService.swift',
      'macos/CapsicumNotificationService/NotificationService.swift',
    ];

    for (final path in nseFiles) {
      test('$path が同じキーを読み、同じ形で添える', () {
        final source = File(path).readAsStringSync();
        expect(
          source,
          contains(
            'static let key = "${NotificationLabelCache.multiAccountKey}"',
          ),
        );
        expect(source, contains(r'return "\(title) (@\(account))"'));
        // 書き換えの経路で実際に使っていること（定義だけで呼ばれていない、を落とす）。
        expect(
          RegExp(
            r'title = NotificationService\.titleWithRecipient\(\s*\S+\.title, '
            r'account: account, multiAccount: MultiAccountFlag\.read\(\)',
          ).hasMatch(source),
          isTrue,
        );
      });
    }
  });
}

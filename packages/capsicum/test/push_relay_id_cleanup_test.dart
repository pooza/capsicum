import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/service/push_key_store.dart';
import 'package:capsicum/src/service/push_registration_service.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #950 の回帰テスト。
///
/// 直したのは **relay 登録 id を読む順序** と、**「1 行消せばデバイス全体が
/// 消える」という旧スキーマ前提**の 2 点。どちらも黙って壊れる形なので固定する。
///
/// - `unregisterAccount` の中の `PushKeyStore.delete(accountKey)` は
///   `_Slot.relayId` を含む全スロットを消す。掃除ループを回した**後**に
///   `getRelayId` を舐めても null しか返らず、`DELETE /register/:id` が一度も
///   発行されない（これが元の症状）
/// - relay の現行スキーマは `UNIQUE(token, account, server)` = **アカウント単位**。
///   N アカウント登録済みなら N 件の id を消す必要がある
///
/// [PushKeyStore] は `static const` の `FlutterSecureStorage` を持ち fake を
/// 差し込めないので、プラグインのメソッドチャネルを in-memory で受ける
/// （`push_key_store_device_token_test.dart` と同じ手）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> store;

  setUp(() {
    store = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
          final key = args['key'] as String?;
          switch (call.method) {
            case 'write':
              store[key!] = args['value'] as String;
              return null;
            case 'read':
              return store[key!];
            case 'delete':
              store.remove(key!);
              return null;
            case 'readAll':
              return Map<String, String>.of(store);
            case 'deleteAll':
              store.clear();
              return null;
            case 'containsKey':
              return store.containsKey(key!);
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('PushRegistrationService.collectRelayIds (#950)', () {
    test('全アカウントぶんの relay id を集める（1 件で打ち切らない）', () async {
      await PushKeyStore.saveRelayId('mastodon://alice@h1', 11);
      await PushKeyStore.saveRelayId('mastodon://bob@h2', 22);
      await PushKeyStore.saveRelayId('mastodon://carol@h3', 33);

      final ids = await PushRegistrationService.collectRelayIds([
        _makeAccount('alice', 'h1'),
        _makeAccount('bob', 'h2'),
        _makeAccount('carol', 'h3'),
      ]);

      expect(ids..sort(), equals([11, 22, 33]));
    });

    test('未登録のアカウントは飛ばす', () async {
      await PushKeyStore.saveRelayId('mastodon://alice@h1', 11);

      final ids = await PushRegistrationService.collectRelayIds([
        _makeAccount('alice', 'h1'),
        _makeAccount('bob', 'h2'),
      ]);

      expect(ids, equals([11]));
    });

    test('同じ id を持つ行が複数あっても DELETE は 1 回に畳む', () async {
      await PushKeyStore.saveRelayId('mastodon://alice@h1', 11);
      await PushKeyStore.saveRelayId('mastodon://bob@h2', 11);

      final ids = await PushRegistrationService.collectRelayIds([
        _makeAccount('alice', 'h1'),
        _makeAccount('bob', 'h2'),
      ]);

      expect(ids, equals([11]));
    });

    test('⚠ 掃除ループの後では何も拾えない（読み出しを先にする理由）', () async {
      await PushKeyStore.saveRelayId('mastodon://alice@h1', 11);
      await PushKeyStore.saveRelayId('mastodon://bob@h2', 22);
      final accounts = [_makeAccount('alice', 'h1'), _makeAccount('bob', 'h2')];

      // unregisterAccount が内部で行うのと同じ削除。
      for (final a in accounts) {
        await PushKeyStore.delete(a.key.toStorageKey());
      }

      expect(await PushRegistrationService.collectRelayIds(accounts), isEmpty);
    });
  });
}

Account _makeAccount(String username, String host) => Account(
  key: AccountKey(type: BackendType.mastodon, host: host, username: username),
  adapter: _MockAdapter(),
  user: _MockUser(),
  userSecret: _MockUserSecret(),
);

class _MockAdapter extends Mock implements DecentralizedBackendAdapter {}

class _MockUser extends Mock implements User {}

class _MockUserSecret extends Mock implements UserSecret {}

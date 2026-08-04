import 'package:capsicum/src/service/push_key_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// #937 で足したデバイス単位のトークンスロットの不変条件を固定する。
///
/// 眼目は **アカウント単位の [PushKeyStore.delete] に巻き添えで消えないこと**。
/// 消えてしまうと、複数アカウントのうち 1 つをログアウトしただけで次回起動の
/// 突き合わせが「未保存」に戻り、再起動をまたいだトークン変化を取りこぼす。
///
/// [PushKeyStore] は `static const` の [FlutterSecureStorage] を持ち fake を
/// 差し込めないので、プラグインのメソッドチャネルを in-memory で受ける。
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

  group('PushKeyStore のデバイストークンスロット (#937)', () {
    test('未保存なら null（初回起動は「変化」と判定できない）', () async {
      expect(await PushKeyStore.getDeviceToken(), isNull);
    });

    test('保存した値を読み戻せる', () async {
      await PushKeyStore.saveDeviceToken('https://wns.example/channel/aaa');
      expect(
        await PushKeyStore.getDeviceToken(),
        equals('https://wns.example/channel/aaa'),
      );
    });

    test('上書きすると最後に書いた値になる', () async {
      await PushKeyStore.saveDeviceToken('old-token');
      await PushKeyStore.saveDeviceToken('new-token');
      expect(await PushKeyStore.getDeviceToken(), equals('new-token'));
    });

    test('アカウント単位の delete では消えない', () async {
      await PushKeyStore.saveDeviceToken('device-token');
      await PushKeyStore.saveRelayId('alice@example.com', 42);
      await PushKeyStore.saveEndpoint(
        'alice@example.com',
        'https://relay/push/x',
      );

      await PushKeyStore.delete('alice@example.com');

      expect(await PushKeyStore.getRelayId('alice@example.com'), isNull);
      expect(await PushKeyStore.getEndpoint('alice@example.com'), isNull);
      expect(await PushKeyStore.getDeviceToken(), equals('device-token'));
    });

    test('deleteDeviceToken で明示的に消せる（デバイス全体を畳んだとき）', () async {
      await PushKeyStore.saveDeviceToken('device-token');
      await PushKeyStore.deleteDeviceToken();
      expect(await PushKeyStore.getDeviceToken(), isNull);
    });

    test('別アカウントの endpoint とキーが衝突しない', () async {
      await PushKeyStore.saveDeviceToken('device-token');
      await PushKeyStore.saveEndpoint(
        'bob@example.com',
        'https://relay/push/y',
      );
      expect(await PushKeyStore.getDeviceToken(), equals('device-token'));
      expect(
        await PushKeyStore.getEndpoint('bob@example.com'),
        equals('https://relay/push/y'),
      );
    });
  });
}

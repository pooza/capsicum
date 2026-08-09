import 'package:capsicum/src/service/device_install_id.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #932 で足したインストール単位 ID の不変条件を固定する。
///
/// relay 側は将来この値をキーに `UNIQUE(account, server, device_id)` で upsert
/// する（capsicum-relay#15）ので、**同じインストールなら常に同じ値**、かつ
/// **1 インストールに 1 つだけ**が守られないと dedup がそのまま壊れる。
///
/// #952 で保存先を SharedPreferences から flutter_secure_storage へ移した。
/// SharedPreferences は OS のバックアップに乗って別筐体へ複製されるため、
/// 復元した端末と元の端末が同じ ID を送ってしまう。ここでは
/// **旧値を引き継がないこと**と **read できない端末では作り直すこと**（Android の
/// 復元直後にマスター鍵が変わっているケース）も固定する。
///
/// [DeviceInstallId] は `static const` の `FlutterSecureStorage` を持ち fake を
/// 差し込めないので、プラグインのメソッドチャネルを in-memory で受ける
/// （PushKeyStore のテストと同じ手法）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> store;
  var readThrows = false;
  var writeThrows = false;

  setUp(() {
    DeviceInstallId.resetForTest();
    SharedPreferences.setMockInitialValues({});
    store = {};
    readThrows = false;
    writeThrows = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
          final key = args['key'] as String?;
          switch (call.method) {
            case 'write':
              if (writeThrows) {
                throw PlatformException(code: 'Exception encrypting message');
              }
              store[key!] = args['value'] as String;
              return null;
            case 'read':
              if (readThrows) {
                throw PlatformException(code: 'Exception decrypting message');
              }
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

  group('DeviceInstallId (#932)', () {
    test('UUID v4 の書式で生成される', () async {
      final id = await DeviceInstallId.get();
      expect(
        id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-'
            r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    });

    test('secure storage に永続化される', () async {
      final id = await DeviceInstallId.get();
      expect(store[DeviceInstallId.storageKey], equals(id));
    });

    test('同一プロセス内で呼び直しても同じ値', () async {
      final first = await DeviceInstallId.get();
      final second = await DeviceInstallId.get();
      expect(second, equals(first));
    });

    test('再起動をまたいでも保存済みの値を返す（新規生成しない）', () async {
      final first = await DeviceInstallId.get();

      // プロセス再起動相当: メモを捨てて secure storage だけ引き継ぐ。
      DeviceInstallId.resetForTest();

      expect(await DeviceInstallId.get(), equals(first));
    });

    test('アカウント数だけ同時に呼んでも 1 つの値に収束する', () async {
      // プッシュ登録はアカウントごとに走るため、起動直後に同時多発で呼ばれる。
      // read → generate → write を各々が回すと別々の ID を書き合い、relay から
      // 1 インストールが複数デバイスに見えてしまう。
      final ids = await Future.wait([
        DeviceInstallId.get(),
        DeviceInstallId.get(),
        DeviceInstallId.get(),
        DeviceInstallId.get(),
        DeviceInstallId.get(),
      ]);

      expect(ids.toSet(), hasLength(1));
      expect(store[DeviceInstallId.storageKey], equals(ids.first));
    });

    test('保存済みの値があれば上書きしない', () async {
      store[DeviceInstallId.storageKey] = 'preexisting-id';

      expect(await DeviceInstallId.get(), equals('preexisting-id'));
    });

    test('空文字が入っていたら生成し直す', () async {
      store[DeviceInstallId.storageKey] = '';

      final id = await DeviceInstallId.get();
      expect(id, isNotEmpty);
      expect(store[DeviceInstallId.storageKey], equals(id));
    });

    test('生成のたびに異なる値になる（別インストールが衝突しない）', () async {
      final ids = <String>{};
      for (var i = 0; i < 20; i++) {
        DeviceInstallId.resetForTest();
        store.clear();
        ids.add(await DeviceInstallId.get());
      }
      expect(ids, hasLength(20));
    });
  });

  group('バックアップ複製への耐性 (#952)', () {
    test('SharedPreferences に残る旧 ID は引き継がない', () async {
      // 旧値を引き継ぐと、バックアップ復元で別筐体へ渡った ID がそのまま
      // 生き残り、relay#15 の upsert で片方の端末に push が届かなくなる。
      SharedPreferences.setMockInitialValues({
        DeviceInstallId.legacyPrefsKey: 'restored-from-backup',
      });

      final id = await DeviceInstallId.get();

      expect(id, isNot(equals('restored-from-backup')));
      expect(store[DeviceInstallId.storageKey], equals(id));
    });

    test('旧 ID は SharedPreferences から掃除される', () async {
      SharedPreferences.setMockInitialValues({
        DeviceInstallId.legacyPrefsKey: 'restored-from-backup',
      });

      await DeviceInstallId.get();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(DeviceInstallId.legacyPrefsKey), isNull);
    });

    test('read できない端末（復元直後の Android 相当）では作り直す', () async {
      // EncryptedSharedPreferences のマスター鍵は Keystore にありバックアップ
      // されないので、復元先では既存エントリを復号できない。
      readThrows = true;

      final id = await DeviceInstallId.get();

      expect(id, isNotEmpty);
      expect(store[DeviceInstallId.storageKey], equals(id));
    });

    test('write も失敗する端末ではプロセス内だけ一貫した値を返す', () async {
      readThrows = true;
      writeThrows = true;

      final ids = await Future.wait([
        DeviceInstallId.get(),
        DeviceInstallId.get(),
        DeviceInstallId.get(),
      ]);

      expect(ids.toSet(), hasLength(1));
      expect(ids.first, isNotEmpty);
    });
  });
}

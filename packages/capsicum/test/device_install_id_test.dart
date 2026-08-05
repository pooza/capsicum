import 'package:capsicum/src/service/device_install_id.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #932 で足したインストール単位 ID の不変条件を固定する。
///
/// relay 側は将来この値をキーに `UNIQUE(account, server, device_id)` で upsert
/// する（capsicum-relay#15）ので、**同じインストールなら常に同じ値**、かつ
/// **1 インストールに 1 つだけ**が守られないと dedup がそのまま壊れる。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DeviceInstallId.resetForTest();
    SharedPreferences.setMockInitialValues({});
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

    test('SharedPreferences に永続化される', () async {
      final id = await DeviceInstallId.get();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(DeviceInstallId.prefsKey), equals(id));
    });

    test('同一プロセス内で呼び直しても同じ値', () async {
      final first = await DeviceInstallId.get();
      final second = await DeviceInstallId.get();
      expect(second, equals(first));
    });

    test('再起動をまたいでも保存済みの値を返す（新規生成しない）', () async {
      final first = await DeviceInstallId.get();

      // プロセス再起動相当: メモを捨てて SharedPreferences だけ引き継ぐ。
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
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(DeviceInstallId.prefsKey), equals(ids.first));
    });

    test('保存済みの値があれば上書きしない', () async {
      SharedPreferences.setMockInitialValues({
        DeviceInstallId.prefsKey: 'preexisting-id',
      });

      expect(await DeviceInstallId.get(), equals('preexisting-id'));
    });

    test('空文字が入っていたら生成し直す', () async {
      SharedPreferences.setMockInitialValues({DeviceInstallId.prefsKey: ''});

      final id = await DeviceInstallId.get();
      expect(id, isNotEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(DeviceInstallId.prefsKey), equals(id));
    });

    test('生成のたびに異なる値になる（別インストールが衝突しない）', () async {
      final ids = <String>{};
      for (var i = 0; i < 20; i++) {
        DeviceInstallId.resetForTest();
        SharedPreferences.setMockInitialValues({});
        ids.add(await DeviceInstallId.get());
      }
      expect(ids, hasLength(20));
    });
  });
}

import 'package:capsicum/src/platform/platform_info.dart';
import 'package:capsicum/src/service/secret_service_probe.dart';
import 'package:capsicum/src/service/secure_storage_gate.dart';
import 'package:capsicum/src/service/shared_item_write_verifier.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// `flutter_secure_storage_linux` の保存の形を写した偽物 (#1387)。
///
/// 全キーを 1 つの項目（[_item]）に持ち、書き込み / 削除のたびに
/// 「読む → 1 キー足す / 消す → 全体を保存」をする（`Secret.hpp` の
/// `addItem` / `deleteItem`）。[dropNextStores] が残っているあいだ、保存は
/// **空で保存される**（gnome-keyring 50.0 のパスワードなしのキーリングで実測
/// した形）。
class _SharedItemStorage extends Fake implements FlutterSecureStorage {
  _SharedItemStorage([Map<String, String>? initial]) : _item = {...?initial};

  Map<String, String> _item;

  /// 次の何回の保存を空にするか。
  int dropNextStores = 0;

  /// ずっと空で保存するか（書き直しの上限の確認用）。
  bool dropAlways = false;

  /// readAll が呼ばれた瞬間に割り込ませる処理（並べる仕掛けの確認用）。
  void Function(int call)? onReadAll;

  int writeCalls = 0;
  int deleteCalls = 0;
  int readAllCalls = 0;

  Map<String, String> get item => Map.unmodifiable(_item);

  void _store(Map<String, String> root) {
    if (dropAlways || dropNextStores > 0) {
      if (dropNextStores > 0) dropNextStores--;
      _item = {};
      return;
    }
    _item = root;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writeCalls++;
    // ⚠ 1 回ずつ譲る。譲らないと呼び出しが互い違いにならず、並べる仕掛け
    // （[SharedItemWriteVerifier] の `_tail`）を外しても緑になる。
    await Future<void>.delayed(Duration.zero);
    final root = {..._item};
    if (value == null) {
      root.remove(key);
    } else {
      root[key] = value;
    }
    _store(root);
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deleteCalls++;
    await Future<void>.delayed(Duration.zero);
    if (!_item.containsKey(key)) return;
    _store({..._item}..remove(key));
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _item[key];

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    readAllCalls++;
    onReadAll?.call(readAllCalls);
    await Future<void>.delayed(Duration.zero);
    return {..._item};
  }
}

void main() {
  final verifier = SharedItemWriteVerifier.instance;

  setUp(() {
    verifier.resetForTest();
    SecretServiceProbe.resetForTest();
    SecretServiceProbe.debugProbeOverride = () async => true;
  });
  tearDown(() {
    verifier.resetForTest();
    SecretServiceProbe.resetForTest();
    // ⚠ null（＝OS の既定）へ戻さない。`flutter_test_config.dart` が既定を
    // false にしている。
    debugSharedSecretItemOverride = false;
    debugSecretServiceOverride = null;
  });

  group('全キーが 1 項目に入らない OS（Apple / Android / Windows）', () {
    setUp(() {
      debugSharedSecretItemOverride = false;
      debugSecretServiceOverride = false;
    });

    test('書き込みは write 1 回だけで、読み戻しも書き直しも走らない', () async {
      final storage = _SharedItemStorage({'a': '1', 'b': '2'})
        ..dropNextStores = 1;
      await SecureStorageGate(storage).write(key: 'c', value: '3');

      expect(storage.writeCalls, 1);
      expect(storage.readAllCalls, 0, reason: '⚠ #1387 より前と同じ呼び出し');
      expect(verifier.rewriteCount, 0);
      expect(
        storage.item,
        isEmpty,
        reason: '書き損じを直さない（直すのは Linux だけ）＝偽物が効いていることの確認',
      );
    });

    test('削除も delete 1 回だけ', () async {
      final storage = _SharedItemStorage({'a': '1', 'b': '2'});
      await SecureStorageGate(storage).delete(key: 'a');

      expect(storage.deleteCalls, 1);
      expect(storage.writeCalls, 0);
      expect(storage.readAllCalls, 0);
    });

    test('読み取りで控えを作らない', () async {
      final storage = _SharedItemStorage({'a': '1'});
      expect(await SecureStorageGate(storage).read(key: 'a'), '1');
      expect(await SecureStorageGate(storage).readAll(), {'a': '1'});

      // 控えがあれば、Linux に切り替えた最初の書き込みで prime の前に
      // 'a' を知っていることになる。prime を空にして見分ける。
      debugSharedSecretItemOverride = true;
      final linux = _SharedItemStorage();
      await SecureStorageGate(linux).write(key: 'z', value: '9');
      expect(linux.item, {'z': '9'}, reason: '他 OS の読み取りが控えに漏れていない');
    });
  });

  group('全キーが 1 項目に入る OS（Linux）', () {
    setUp(() {
      debugSharedSecretItemOverride = true;
      debugSecretServiceOverride = true;
    });

    test('書き込みが空で保存されたら、ほかのキーを書き直して揃える', () async {
      final storage = _SharedItemStorage({
        'secret_a': 'token-a',
        'client_creds_a': 'creds-a',
      })..dropNextStores = 1;

      await SecureStorageGate(storage).write(key: 'secret_b', value: 'token-b');

      expect(storage.item, {
        'secret_a': 'token-a',
        'client_creds_a': 'creds-a',
        'secret_b': 'token-b',
      });
    });

    test('起動して何も読まずに書いても、先に全体を読んで守る', () async {
      // 控えが空のまま最初の書き込みが空で保存されると、控えが
      // 'secret_b' しか知らず「揃っている」と見なしてしまう。
      final storage = _SharedItemStorage({'secret_a': 'token-a'})
        ..dropNextStores = 1;
      await SecureStorageGate(storage).write(key: 'secret_b', value: 'token-b');

      expect(storage.item['secret_a'], 'token-a');
    });

    test('書き直しの元は控えで、読み戻した値ではない', () async {
      final storage = _SharedItemStorage({'secret_a': 'token-a'});
      final gate = SecureStorageGate(storage);
      await gate.write(key: 'secret_b', value: 'token-b');

      // 書き込みのあいだに 2 回続けて空で保存される（1 回目の書き直しも落ちる）。
      storage.dropNextStores = 2;
      await gate.write(key: 'secret_c', value: 'token-c');

      expect(storage.item, {
        'secret_a': 'token-a',
        'secret_b': 'token-b',
        'secret_c': 'token-c',
      });
    });

    test('読み戻しに無いキーで控えを消さない（次の書き込みでも戻る）', () async {
      final storage = _SharedItemStorage({'secret_a': 'token-a'});
      final gate = SecureStorageGate(storage);
      expect(await gate.read(key: 'secret_a'), 'token-a');

      // 書き込みの外で項目が空になった（前のプロセスの書き損じなど）。
      storage.dropNextStores = 1;
      await storage.write(key: 'noise', value: 'x');
      expect(await gate.read(key: 'secret_a'), isNull);

      await gate.write(key: 'secret_b', value: 'token-b');
      expect(storage.item['secret_a'], 'token-a');
    });

    test('削除したキーは書き直しで生き返らない', () async {
      final storage = _SharedItemStorage({
        'secret_a': 'token-a',
        'secret_b': 'token-b',
      });
      final gate = SecureStorageGate(storage);
      await gate.readAll();

      storage.dropNextStores = 1;
      await gate.delete(key: 'secret_a');

      expect(storage.item, {'secret_b': 'token-b'});
    });

    test('ずっと空で保存されるなら、上限で諦めて元の書き込みは成功で返す', () async {
      final storage = _SharedItemStorage({
        'secret_a': 'token-a',
        'secret_b': 'token-b',
      });
      final gate = SecureStorageGate(storage);
      await gate.readAll();
      storage.dropAlways = true;

      await gate.write(key: 'secret_c', value: 'token-c');

      // 1 周で食い違う 3 キーを書き直す × 上限の周回。
      expect(
        verifier.rewriteCount,
        3 * SharedItemWriteVerifier.maxRewriteRounds,
      );
      expect(verifier.reportedForTest, isTrue);

      // 次の書き込みでも上限で止まる（無限に回らない）。
      final before = verifier.rewriteCount;
      await gate.write(key: 'secret_d', value: 'token-d');
      expect(
        verifier.rewriteCount - before,
        4 * SharedItemWriteVerifier.maxRewriteRounds,
      );
    });

    test('2 つの店が同時に書いても、互いの書き直しで消し合わない', () async {
      // 4 店は Linux で同じ 1 項目を共有する。
      final storage = _SharedItemStorage({'secret_a': 'token-a'});
      final accounts = SecureStorageGate(storage);
      final push = ReportingSecureStorageGate(
        _PushStorageSlot(storage),
        phase: 'x',
      );

      storage.dropNextStores = 1;
      await Future.wait([
        accounts.write(key: 'secret_b', value: 'token-b'),
        push.write(key: 'push_key', value: 'pk'),
      ]);

      expect(storage.item, {
        'secret_a': 'token-a',
        'secret_b': 'token-b',
        'push_key': 'pk',
      });
    });

    test('書き直しの最中に別の店が消したキーを、書き直しで生き返らせない', () async {
      // 並べないと、書き込みの読み戻しで「欠けている」と数えたあとに削除が
      // 走り、その古い数え方のまま書き直して、消したキーが戻る。
      final storage = _SharedItemStorage({
        'secret_a': 'token-a',
        'secret_b': 'token-b',
      });
      final accounts = SecureStorageGate(storage);
      final push = ReportingSecureStorageGate(
        _PushStorageSlot(storage),
        phase: 'x',
      );
      await accounts.write(key: 'secret_c', value: 'token-c');

      // push の書き込みが空で保存され、その読み戻しが始まった瞬間に削除を
      // 割り込ませる。
      final calls = storage.readAllCalls;
      Future<void>? deletion;
      storage
        ..dropNextStores = 1
        ..onReadAll = (call) {
          if (call == calls + 1) {
            deletion = accounts.delete(key: 'secret_a');
          }
        };
      await push.write(key: 'push_key', value: 'pk');
      await deletion;

      expect(storage.item, {
        'secret_b': 'token-b',
        'secret_c': 'token-c',
        'push_key': 'pk',
      });
    });

    test('元の書き込みが失敗したら、控えを変えずにそのまま投げる', () async {
      final storage = _FailingWriteStorage({'secret_a': 'token-a'});
      final gate = SecureStorageGate(storage);

      await expectLater(
        gate.write(key: 'secret_b', value: 'token-b'),
        throwsA(isA<StateError>()),
      );

      // 控えに 'secret_b' が入っていれば、次の書き込みの書き直しで現れる。
      storage.failWrites = false;
      await gate.write(key: 'secret_c', value: 'token-c');
      expect(storage.item.containsKey('secret_b'), isFalse);
    });
  });
}

/// 別の店（`PushKeyStore` など）が同じ項目へ届くための中継。
class _PushStorageSlot extends Fake implements FlutterSecureStorage {
  _PushStorageSlot(this.backing);

  final _SharedItemStorage backing;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => backing.write(key: key, value: value);

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => backing.readAll();
}

class _FailingWriteStorage extends _SharedItemStorage {
  _FailingWriteStorage(super.initial);

  bool failWrites = true;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (failWrites) throw StateError('write failed');
    return super.write(key: key, value: value);
  }
}

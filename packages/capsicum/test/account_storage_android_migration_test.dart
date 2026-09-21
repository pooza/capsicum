import 'package:capsicum/src/service/account_storage.dart';
import 'package:capsicum/src/service/secure_storage_gate.dart';
import 'package:capsicum/src/util/login_error.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v1.66 リリース前レビュー: Android で `flutter_secure_storage` 10 の移行が
/// 失敗し続ける端末でも、ログインし直せば抜け出せる。
///
/// ⚠ fake はプラグインの作りを真似る: `resetOnError: false`（店の既定）の呼び出し
/// は初期化（＝移行）の失敗で例外になり、`resetOnError: true` の呼び出しだけが
/// 全消去を経て書き込みへ進む（`FlutterSecureStorage.java` の `initialize`）。
class _MigrationFailingStorage extends FlutterSecureStorage {
  final Map<String, String> data = {'secret_old': 'unreadable'};
  int resetWrites = 0;

  static final _failure = PlatformException(
    code: 'Exception encountered',
    message:
        'Migration failed after algorithm change (x). '
        'Enable resetOnError=true or call deleteAll().',
  );

  bool _resets(AndroidOptions? o) => o?.params['resetOnError'] == 'true';

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
    if (!_resets(aOptions)) throw _failure;
    resetWrites++;
    data
      ..clear()
      ..[key] = value!;
  }

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    // ⚠ 初期化が失敗するので deleteAll も同じ例外で落ちる（抜け道にならない）。
    if (!_resets(aOptions)) throw _failure;
    data.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('⚠⚠ 移行が失敗し続けても、ログインの保存は消してから書き直して通る', () async {
    final storage = _MigrationFailingStorage();

    await AccountStorage(storage).saveAccount('mastodon://a@h', {'token': 't'});

    expect(storage.resetWrites, 1, reason: '回復の書き込みは 1 回だけ');
    expect(storage.data.keys, ['secret_mastodon://a@h'], reason: '読めない残骸は消える');
  });

  test('判定: プラグインの 2 つの文言を拾い、他の PlatformException は拾わない', () {
    expect(
      isAndroidSecureStorageMigrationFailure(
        PlatformException(
          code: 'Exception encountered',
          message: 'Key mismatch after algorithm change (y). ...',
        ),
      ),
      isTrue,
    );
    expect(
      isAndroidSecureStorageMigrationFailure(
        PlatformException(
          code: '-25308',
          message: 'errSecInteractionNotAllowed',
        ),
      ),
      isFalse,
    );
  });

  test('回復でも書けなかったら、保管庫が原因だと分かる文言を出す', () {
    final r = classifyLoginFailure(
      PlatformException(
        code: 'Exception encountered',
        message: 'Migration failed after algorithm change (x).',
      ),
    );
    expect(r.kind, LoginFailureKind.secureStorage);
    expect(r.message, contains('パスワード保管庫'));
  });
}

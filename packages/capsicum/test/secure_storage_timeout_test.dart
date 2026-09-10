import 'dart:async';

import 'package:capsicum/src/constants.dart';
import 'package:capsicum/src/platform/platform_info.dart';
import 'package:capsicum/src/service/account_storage.dart';
import 'package:capsicum/src/service/secret_service_probe.dart';
import 'package:capsicum/src/service/secure_storage_health.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1085: secure storage が**応答しない**ときに待ち続けない。
///
/// Linux の flutter_secure_storage は libsecret → D-Bus
/// `org.freedesktop.secrets` に落ちるので、gnome-keyring（Secret Service）が
/// 死んでいると応答が返らない。⚠⚠ **呼び出し側は全部 `try`/`catch` で囲んで
/// あるが、ハングは例外ではないので catch されない。**その結果 `runApp()` の
/// 手前で止まり、ユーザーには**真っ黒なウインドウと無反応**しか見えなかった。
class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  /// ⚠⚠ **この 2 件は macOS で緑・Linux CI で赤になっていた**（2026-09-10）。
  ///
  /// `AccountStorage._read` は #1085 で [SecretServiceProbe] を先に通すように
  /// なった。`usesSecretService` は **Linux でだけ true** なので、
  ///
  /// - **macOS の手元** — 素通りして従来どおり通る
  /// - **Linux の CI** — 本物の D-Bus 疎通を試みる。⚠ **`fakeAsync` の中では
  ///   実 I/O が進まない**ので `_probeTimeout`（800ms）の**タイマーだけ**が
  ///   `async.elapse` で発火し、**読み取りの上限（5 秒）より先に**打ち切られる
  ///
  /// → **OS で結果が変わる形だった。**両方の口を塞いで、**どの OS でも Linux の
  /// 経路を通す**。⚠ **「macOS では走らない」ままにしない** —— それだと
  /// この 2 件が守っているはずの #1085 の本体（Linux）を、手元では一度も
  /// 踏まないことになる。
  setUp(() {
    SecureStorageHealth.resetForTest();
    SecretServiceProbe.resetForTest();
    // Linux のふりをする（＝probe を必ず通す経路に乗せる）。
    debugSecretServiceOverride = true;
    // ⚠ **その probe は「応答する」と答える。**ここで止まると、この 2 件が
    // 見たい「読み取り自体が返らない」ケースへ到達できない。
    SecretServiceProbe.debugProbeOverride = () async => true;
  });
  tearDown(() {
    SecureStorageHealth.resetForTest();
    SecretServiceProbe.resetForTest();
    debugSecretServiceOverride = null;
  });

  test('応答が返らない読み取りは打ち切る', () {
    final storage = _MockSecureStorage();
    // 返らない Future ＝ Secret Service が応答しない状態。
    when(
      () => storage.read(key: any(named: 'key')),
    ).thenAnswer((_) => Completer<String?>().future);

    fakeAsync((async) {
      Object? thrown;
      AccountStorage(
        storage,
      ).getSecrets('mastodon://alice@mstdn.example').catchError((Object e) {
        thrown = e;
        return null;
      });

      async.elapse(kSecureStorageReadTimeout - const Duration(milliseconds: 1));
      expect(thrown, isNull, reason: '上限より前に諦めない');

      async.elapse(const Duration(milliseconds: 2));
      expect(
        thrown,
        isA<TransientSecretUnavailableException>(),
        reason:
            '⚠ **null（＝secret が存在しない）にしてはいけない。**secret は無傷'
            'なので、ログアウト扱いにすると読めるようになっても戻らない',
      );
      expect(
        SecureStorageHealth.unavailable,
        isTrue,
        reason: '案内を出すために、応答しなかったことを記録する',
      );
    });
  });

  test('⚠⚠ 読めなかった後に読めたら、案内を下ろす', () {
    // #1085: 再試行で復帰できるようにしたので、旗を立てっぱなしにすると
    // キーリングが直ったあとも「読み出せません」の案内が残る。
    SecureStorageHealth.markRefused(Exception('Failed to unlock the keyring'));
    expect(SecureStorageHealth.unavailable, isTrue);

    final storage = _MockSecureStorage();
    when(
      () => storage.read(key: any(named: 'key')),
    ).thenAnswer((_) async => '{"access_token":"t"}');

    fakeAsync((async) {
      AccountStorage(storage).getSecrets('mastodon://alice@mstdn.example');
      async.elapse(const Duration(milliseconds: 1));
      expect(SecureStorageHealth.unavailable, isFalse);
    });
  });

  test('⚠ item が無い（null）読み取りでも案内を下ろす', () {
    // 読めないのではなく、読んだ結果が空だった。キーリングは応答している。
    SecureStorageHealth.markRefused(Exception('Failed to unlock the keyring'));

    final storage = _MockSecureStorage();
    when(
      () => storage.read(key: any(named: 'key')),
    ).thenAnswer((_) async => null);

    fakeAsync((async) {
      AccountStorage(storage).getSecrets('mastodon://alice@mstdn.example');
      async.elapse(const Duration(milliseconds: 1));
      expect(SecureStorageHealth.unavailable, isFalse);
    });
  });

  test('応答が返れば従来どおり読める', () {
    final storage = _MockSecureStorage();
    when(
      () => storage.read(key: any(named: 'key')),
    ).thenAnswer((_) async => '{"access_token":"t"}');

    fakeAsync((async) {
      Map<String, String>? secrets;
      AccountStorage(
        storage,
      ).getSecrets('mastodon://alice@mstdn.example').then((v) => secrets = v);
      async.elapse(const Duration(milliseconds: 1));

      expect(secrets, {'access_token': 't'});
      expect(
        SecureStorageHealth.unavailable,
        isFalse,
        reason: '成功した読み取りで案内を出さない',
      );
    });
  });
}

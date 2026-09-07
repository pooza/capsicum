import 'dart:async';

import 'package:capsicum/src/constants.dart';
import 'package:capsicum/src/service/account_storage.dart';
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
  setUp(SecureStorageHealth.resetForTest);
  tearDown(SecureStorageHealth.resetForTest);

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

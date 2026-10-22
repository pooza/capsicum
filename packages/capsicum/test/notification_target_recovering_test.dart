import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/model/offline_account.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1304: 起動の締切（#1294）で「遅いだけ」のサーバーのアカウントがオフライン扱いの
/// 間に通知をタップすると、今のアカウントの通知が開いていた。宛先がまだ戻って
/// いないが再試行で戻りうるなら、通知の経路は待つ。
void main() {
  const slow = AccountKey(
    type: BackendType.mastodon,
    host: 'slow.example',
    username: 'alice',
  );

  test('⚠ 再試行で戻りうるオフラインのアカウント宛てなら待つ', () {
    expect(
      notificationTargetIsRecovering(const [
        OfflineAccount(key: slow),
      ], 'alice@slow.example'),
      isTrue,
    );
  });

  test('ログインし直しが要るアカウント（secret が消えた）は待っても戻らない', () {
    expect(
      notificationTargetIsRecovering(const [
        OfflineAccount.secretMissing(key: slow),
      ], 'alice@slow.example'),
      isFalse,
    );
  });

  test('別のアカウント宛て・オフラインに居ない宛てなら待たない', () {
    const offline = [OfflineAccount(key: slow)];
    expect(
      notificationTargetIsRecovering(offline, 'bob@slow.example'),
      isFalse,
    );
    expect(
      notificationTargetIsRecovering(offline, 'alice@other.example'),
      isFalse,
    );
    expect(
      notificationTargetIsRecovering(const [], 'alice@slow.example'),
      isFalse,
    );
  });

  test('宛先の形が壊れていれば待たない', () {
    const offline = [OfflineAccount(key: slow)];
    expect(notificationTargetIsRecovering(offline, 'no-at-sign'), isFalse);
    expect(notificationTargetIsRecovering(offline, '@slow.example'), isFalse);
  });
}

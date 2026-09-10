import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// secure storage が応答したかどうかを 1 箇所で持つ (#1085)。
///
/// ## なぜ要るか
///
/// Linux の flutter_secure_storage は libsecret → D-Bus
/// `org.freedesktop.secrets` に落ちる。**gnome-keyring（Secret Service）が
/// 死んでいると応答が返らない。**呼び出し側はどこも `try`/`catch` で囲んで
/// あるが、**ハングは例外ではないので catch されない**。
///
/// ⚠⚠ **ユーザーに見えるのは「真っ黒なウインドウと無反応」だけで、原因
/// （キーリング）に辿り着く手掛かりが何も出ない。**報告者は「アプリの更新で
/// 壊れた」と受け取り、v1.58 まで遡って試して初めて正しい原因に到達した。
/// タイムアウトを入れて先へ進めるだけでは足りず、**何が起きたかを言う**必要が
/// ある。
///
/// ## 使い方
///
/// 読み取りが [kSecureStorageReadTimeout] を超えたら [markUnavailable] を
/// 呼ぶ。UI は [notifier] を `ValueListenableBuilder` で見て、案内を足す。
///
/// ⚠ **riverpod ではなく `ValueNotifier`。**印を付けるのは `ref` を持たない
/// storage 層で、そこから provider を触れるようにすると依存が逆流する。
class SecureStorageHealth {
  SecureStorageHealth._();

  /// secure storage から**今**読み出せない状態か。
  ///
  /// ⚠ **読み取りが成功したら下ろす**（[markRecovered]）。以前は「回復しても
  /// 戻さない」だったが、#1085 で再試行から復帰できるようにしたので、戻さないと
  /// **キーリングが直ったあとも「読み出せません」の案内が残る**（別の理由で
  /// オフラインになったアカウントの画面に、嘘の原因が出る）。
  static final ValueNotifier<bool> notifier = ValueNotifier<bool>(false);

  static bool get unavailable => notifier.value;

  /// Sentry へ送ったか。⚠ **1 プロセス 1 回。**アカウントの数だけ同じ事実を
  /// 送っても母数が水増しされるだけ。
  static bool _reported = false;

  /// 応答が無かったことを記録する。
  static void markUnavailable(TimeoutException cause) {
    debugPrint(
      'capsicum: secure storage did not respond within '
      '${cause.duration?.inMilliseconds}ms',
    );
    notifier.value = true;
    if (_reported) return;
    _reported = true;
    unawaited(
      Sentry.captureMessage(
        'secure_storage.timeout',
        level: SentryLevel.warning,
        withScope: (scope) {
          scope.setTag('phase', 'startup_secret');
          // ⚠ 鍵の名前もアカウントも載せない。知りたいのは「応答しない環境が
          // 実在するか」だけで、どの item かは関係ない。
          scope.setContexts('secure_storage', {
            'timeout_ms': cause.duration?.inMilliseconds,
          });
        },
      ),
    );
  }

  /// **応答は返ったが読めなかった**ことを記録する (#1104)。
  ///
  /// ⚠ **[markUnavailable] と同じ旗を立てる。**ユーザーから見ると「ログイン情報
  /// が読めない」で同じで、次の一手（ほかのアプリでも失敗していないか・端末を
  /// 再起動する）も同じ。⚠ **区別が要るのは開発側だけ**で、そちらは Sentry の
  /// 例外（`_reportOnce`）が持っている。
  ///
  /// ⚠ **ここでは Sentry へ送らない。**呼び出し側が例外そのものを送っているので、
  /// 同じ事実を 2 回上げると母数が二重に見える。
  static void markRefused(Object cause) {
    debugPrint('capsicum: secure storage refused the read: $cause');
    notifier.value = true;
  }

  /// 読み取りが成功した（＝キーリングが応答し、解錠もできた）ことを記録する
  /// (#1085)。
  ///
  /// ⚠ **Sentry の送信済みフラグは戻さない。**1 プロセス 1 回の母数を保つ。
  static void markRecovered() {
    if (!notifier.value) return;
    debugPrint('capsicum: secure storage is readable again');
    notifier.value = false;
  }

  @visibleForTesting
  static void resetForTest() {
    notifier.value = false;
    _reported = false;
  }
}

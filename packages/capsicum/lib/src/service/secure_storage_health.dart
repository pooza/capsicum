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

  /// 「secure storage が応答しなかった」ことがこのプロセスで一度でもあったか。
  ///
  /// ⚠ **回復しても false へ戻さない。**戻せる根拠（次の読み取りが成功した）を
  /// 得られるのは実際に読みに行ったときだけで、その頃には画面から案内が消えて
  /// いてほしいとは限らない。プロセスを跨がないので、再起動すれば消える。
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

  @visibleForTesting
  static void resetForTest() {
    notifier.value = false;
    _reported = false;
  }
}

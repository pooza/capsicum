import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import '../platform/platform_info.dart';
import '../util/exception_scrub.dart';

/// Secret Service が**応答するか**を、libsecret に触らずに確かめる (#1085)。
///
/// ## ⚠⚠ なぜ Dart 側のタイムアウトでは足りなかったか
///
/// `flutter_secure_storage_linux` は**メソッドチャネルのハンドラの中で
/// `secret_password_lookupv_sync` を直に呼ぶ**（`method_call_cb` はワーカー
/// スレッドを使わない。3.0.2 でも同じ）。ハンドラが走るのは**プラットフォーム
/// スレッド**で、そこは GTK のメインループ＝**フレームを提示するスレッド**でも
/// ある。
///
/// → **Secret Service が `SIGSTOP` 等で応答しないと、そのスレッドが D-Bus 呼び
/// 出しの中で止まる。**`kSecureStorageReadTimeout` は Dart 側のタイマーなので
/// 発火はするが、**旗を立てても描くスレッドが居ない**ので画面は真っ黒のまま。
///
/// ⚠⚠ **実際に報告者の環境でそうなった**（2026-09-09）。Sentry には
/// `secure_storage.timeout` が届いているのに、ユーザーには黒いウインドウしか
/// 見えず、赤いカードも出なかった。**「タイムアウトを入れた」だけでは、この
/// 故障モードは 1mm も改善しない。**
///
/// ## どう確かめるか
///
/// **libsecret を経由しない**（＝プラットフォームスレッドを使わない）純 Dart の
/// D-Bus で聞く。`dbus` パッケージは `Socket` を使う非同期実装なので、待っても
/// 止まるのは Dart の 1 つの Future だけ。
///
/// 1. **`NameHasOwner('org.freedesktop.secrets')`** — 答えるのは
///    `dbus-daemon` 自身なので、**Secret Service が固まっていても必ず速く返る**
/// 2. 所有者が居たら **`org.freedesktop.DBus.Peer.Ping`** を投げる。⚠ **これは
///    固まっているプロセスへ届くので返らない** → [_probeTimeout] で打ち切る
///
/// ⚠ **`ListNames` ではなく `NameHasOwner` を使う。**前者は全名前を舐めるので
/// 無駄が大きいうえ、**activatable なだけで起動していないサービス**の扱いが
/// 分かりにくい。
///
/// ⚠ **所有者が居ないときは「応答する」を返す。**その場合 libsecret は D-Bus
/// activation で起動を試み、失敗すれば**例外で速やかに返る**（#1104 の経路）。
/// 固まるのは「居るのに返らない」ときだけなので、ここで止める理由が無い。
///
/// ## ⚠ 取りこぼす窓はある
///
/// 確認の直後に固まった場合は素通りする。**報告された故障モード（起動時点で
/// 既に応答しない）は塞がる**が、これは完全な保証ではない。根本の直しは
/// プラグイン側を非同期化することで、そちらは upstream の仕事。
class SecretServiceProbe {
  SecretServiceProbe._();

  /// Secret Service の well-known name。
  static const _busName = 'org.freedesktop.secrets';

  /// `Ping` の待ち上限。
  ///
  /// ⚠ **短くてよい。**生きていれば同一マシンの D-Bus 往復なのでミリ秒で返る。
  /// ⚠ **長くすると起動がその分遅れる**（応答しない環境では毎回満了する）。
  static const _probeTimeout = Duration(milliseconds: 800);

  /// 確かめた結果。
  ///
  /// ⚠ **true は持ち続ける**（毎回聞くと、アカウントの数だけ往復が増える）。
  /// ⚠ **false は再試行の 1 周の頭で捨てる**（[forgetUnresponsive]）。
  ///
  /// ⚠⚠ **以前は false をプロセス終了まで持っていた。**「復旧したかを知るには
  /// 実際に触るしかない」と考えていたが、**誤り**だった —— [_ping] は libsecret
  /// を通らない純 Dart の D-Bus で、相手が固まっていても [_probeTimeout] で
  /// 打ち切れる。確かめ直しても固まらない。そのせいで、キーリングが戻っても
  /// **「今すぐ再試行」を押して何も起こらず、再起動するまで復帰しなかった**
  /// （#1085・報告者の 181 の検証で判明）。
  static bool? _cached;

  /// テスト用の差し替え口。
  ///
  /// ⚠ **これが無いと、Linux でしか走らない分岐の検査が他 OS で素通りする**
  /// （#1085 で `Platform.isIOS || Platform.isMacOS` を直書きして踏んだ形）。
  @visibleForTesting
  static Future<bool> Function()? debugProbeOverride;

  /// テスト用。キャッシュ（true / false とも）と差し替え口を空にする。
  @visibleForTesting
  static void resetForTest() {
    _cached = null;
    debugProbeOverride = null;
  }

  /// 「応答しない」と覚えた結果だけを捨て、次の [isResponsive] で確かめ直す
  /// (#1085)。
  ///
  /// オフラインのアカウントを読み直す**再試行の 1 周の頭**で呼ぶ（手動の
  /// 「今すぐ再試行」・フォアグラウンド復帰・背景ループの 3 経路とも同じ関数を
  /// 通る）。⚠ **1 周で 1 回。**アカウントごとに呼ぶと、応答しない環境で
  /// アカウントの数だけ [_probeTimeout] を払う。
  ///
  /// ⚠ **true は捨てない。**応答している間は聞き直す理由が無い。
  static void forgetUnresponsive() {
    if (_cached == false) _cached = null;
  }

  /// **触ったら固まった**ことを覚える (#1117-C)。
  ///
  /// ⚠⚠ **確認が true でも、その後の読み書きは固まりうる。**確認と実際の呼び出し
  /// の間に落ちた場合がそれで、以前は**キャッシュが true のまま**だったため、
  /// **後続のアカウントが 1 件ごとに [kSecureStorageReadTimeout]（5 秒）を払って
  /// いた**（10 アカウントで 50 秒）。1 件でも固まったら、その 1 周は触らない。
  ///
  /// ⚠ **false は [forgetUnresponsive] が次の 1 周の頭で捨てる**ので、復旧の
  /// 妨げにはならない。
  static void markUnresponsive() {
    if (!usesSecretService) return;
    _cached = false;
  }

  /// secure storage に触ってよいか。
  ///
  /// ⚠ **Secret Service を使わない OS では常に true。**Apple の Keychain /
  /// Android の Keystore / Windows の DPAPI は D-Bus を経由しないので、
  /// 確かめる相手が居ない。
  static Future<bool> isResponsive() async {
    if (!usesSecretService) return true;
    final cached = _cached;
    if (cached != null) return cached;

    final override = debugProbeOverride;
    final result = await (override ?? _ping)();
    _cached = result;
    return result;
  }

  static Future<bool> _ping() async {
    DBusClient? opened;
    try {
      // ⚠ **生成も try の中。**セッションバスのアドレスが決められないと同期的
      // に投げうるので、外に置くと下の「素通りさせる」に届かず、
      // `getSecrets` の汎用 catch（読めなかった扱い）へ落ちる。
      final client = opened = DBusClient.session();
      // 1. dbus-daemon への問い合わせ。⚠ **相手が固まっていても速く返る。**
      final hasOwner = await client
          .nameHasOwner(_busName)
          .timeout(_probeTimeout);
      // 所有者が居ないなら activation 待ち。固まる経路ではない（上の doc）。
      if (!hasOwner) return true;

      // 2. 所有者そのものへ Ping。⚠ **固まっていればここで返らない。**
      final object = DBusRemoteObject(
        client,
        name: _busName,
        path: DBusObjectPath('/org/freedesktop/secrets'),
      );
      await object
          .callMethod(
            'org.freedesktop.DBus.Peer',
            'Ping',
            [],
            replySignature: DBusSignature(''),
          )
          .timeout(_probeTimeout);
      return true;
    } on TimeoutException {
      debugPrint(
        'capsicum: secret service did not answer Ping within '
        '${_probeTimeout.inMilliseconds}ms; skipping secure storage (#1085)',
      );
      return false;
    } catch (e) {
      // ⚠ **セッションバスが無い / 権限が無いは「応答しない」ではない。**
      // その場合 libsecret も同じ理由で速やかに例外を返すので、素通りさせて
      // 通常の失敗経路（#1104）に載せる。
      //
      // ⚠ **`debugPrint('… $e')` と書かないこと (#1035-B)。**release の
      // `debugPrint` は breadcrumb 化され、`_scrubBreadcrumb` は message に
      // relay の push token マスクしか当てない。⚠ **これを書いて実際に
      // `exception_scrub_guard_test` に落とされた。**
      debugLogException('capsicum: secret service probe could not run', e);
      return true;
    } finally {
      // ⚠ close 自体は待たない。⚠ **応答しないバス相手に await すると、
      // ここで新しい待ちを作ってしまう**（塞ぎたかったものと同じ形）。
      final client = opened;
      if (client != null) unawaited(client.close().catchError((_) {}));
    }
  }
}

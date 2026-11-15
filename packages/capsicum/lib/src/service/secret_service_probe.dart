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
    debugLockedOverride = null;
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

  /// capsicum の項目が入ったキーリングが**ロックされているか** (#1386)。
  ///
  /// ## なぜ要るのか
  ///
  /// ロックされたキーリングを `flutter_secure_storage_linux` で読むと、
  /// libsecret が **OS のロック解除の画面**を出す。オフラインのアカウントの
  /// 自動の再試行（60 秒ごと）がそのたびに読むので、**Cancel しても約 60 秒
  /// ごとに画面全体を覆う解除の画面が出続けていた。**[isResponsive] は
  /// 「居ない / 応答しない」は見るが、「居て応答するがロックされている」は
  /// 見ていなかった。
  ///
  /// ## どう確かめるか
  ///
  /// Secret Service の `SearchItems` は、属性に合う項目を**解除済み**と
  /// **ロック中**の 2 つの一覧で返し、**解除の画面は出さない**（仕様）。
  /// [_ping] と同じ純 Dart の D-Bus で呼ぶので、プラットフォームスレッドも
  /// 使わない。属性はプラグインが付けるもの（`account` =
  /// `<APPLICATION_ID>.secureStorage`）。
  ///
  /// - 解除済みが 1 件でもあれば false（読める）
  /// - 解除済みが 0 件で、ロック中が 1 件以上なら true
  /// - ⚠ **どちらも 0 件なら false。**項目がまだ無い（初回）か、消えている。
  ///   読んでも解除の画面は出ないので止める理由が無い
  /// - ⚠ **確かめられなかったら false。**ここで止めると、確かめる手段が
  ///   壊れているだけで自動の再試行が永久に止まる。従来どおり読みに行く
  ///
  /// ⚠ Secret Service を使わない OS では常に false。
  static Future<bool> isLocked() async {
    if (!usesSecretService) return false;
    final override = debugLockedOverride ?? debugLockedFallback;
    if (override != null) return override();
    return _searchLocked();
  }

  /// テスト用の差し替え口 (#1386)。[resetForTest] で空に戻る。
  @visibleForTesting
  static Future<bool> Function()? debugLockedOverride;

  /// テスト全体の既定（`test/flutter_test_config.dart` が「ロックされて
  /// いない」を入れる）。⚠ [resetForTest] では消さない。
  ///
  /// ⚠⚠ **これが無いと、Linux の上のテストが本物の D-Bus に問い合わせる。**
  /// `fakeAsync` の中では本物の通信が終わらないので、オフラインの再試行の
  /// ループが進まなくなる（`offline_retry_loop_transient_test` が inori で
  /// 落ちた・Mac では分岐を通らないので緑のまま）。
  @visibleForTesting
  static Future<bool> Function()? debugLockedFallback;

  /// プラグインが項目に付ける `account` 属性の値（`linux/CMakeLists.txt` の
  /// `APPLICATION_ID` + `.secureStorage`・`flutter_secure_storage_linux_plugin.cc`）。
  static const _accountAttribute = 'net.shrieker.capsicum.secureStorage';

  static Future<bool> _searchLocked() async {
    DBusClient? opened;
    try {
      final client = opened = DBusClient.session();
      final service = DBusRemoteObject(
        client,
        name: _busName,
        path: DBusObjectPath('/org/freedesktop/secrets'),
      );
      final reply = await service
          .callMethod('org.freedesktop.Secret.Service', 'SearchItems', [
            DBusDict(DBusSignature('s'), DBusSignature('s'), {
              const DBusString('account'): const DBusString(_accountAttribute),
            }),
          ], replySignature: DBusSignature('aoao'))
          .timeout(_probeTimeout);
      final unlocked = (reply.values[0] as DBusArray).children;
      final locked = (reply.values[1] as DBusArray).children;
      return unlocked.isEmpty && locked.isNotEmpty;
    } catch (e) {
      debugLogException('capsicum: secret service lock check could not run', e);
      return false;
    } finally {
      final client = opened;
      if (client != null) unawaited(client.close().catchError((_) {}));
    }
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

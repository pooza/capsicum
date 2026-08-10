import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// このインストールを一意に指す ID（#932 / #952 / capsicum-relay#15）。
///
/// capsicum-relay の `subscriptions` は `UNIQUE(token, account, server)` で
/// 行を管理しているため、**デバイスの push トークンが更新されると衝突せずに
/// 新しい行が作られ、旧行が孤児として残る**。relay 側で
/// `(account, server, device_type)` に潰す案は iPhone + iPad のような正当な
/// 複数デバイス運用を壊すので採れず、**client が「同じインストールか」を
/// 示す値を送る**のが前提になる。ここがその値。
///
/// 設計上の制約が 3 つある。
///
/// - **粒度はインストール単位**。1 端末に N アカウントをぶら下げても ID は
///   1 つ。relay 側は `UNIQUE(account, server, device_id)` に組み替えるため、
///   アカウントごとに変えると dedup が効かない。
/// - **ハードウェア識別子は使わない**（IDFV / ANDROID_ID / MachineGuid 等）。
///   ストアのポリシー上の制約があるうえ、端末の同定が目的ではなく「同じ
///   インストールか」が分かれば足りる。よって乱数 UUID v4。
/// - **保存先は「別筐体へ複製されない」場所**でなければならない。#932 の初版は
///   SharedPreferences に置いていたが、これは Android Auto Backup（既定 ON・
///   `shared_prefs/` を含む）と iOS の iCloud / 暗号化バックアップ
///   （NSUserDefaults = `Library/Preferences/*.plist`）の対象で、**機種変で
///   復元した端末が元の端末と同じ ID を送る**。relay#15 の
///   `UNIQUE(account, server, device_id)` upsert が入った瞬間、後から登録した
///   側が先の行を上書きし、**もう一方の端末に push が届かなくなる** (#952)。
///
/// ## 保存先（#952）
///
/// flutter_secure_storage に置く。狙いは機密性ではなく **寿命** で、
/// 「同じ物理端末なら同じ値・別筐体なら別値」だけが要件。
///
/// - **iOS / macOS**: [KeychainAccessibility.first_unlock_this_device]
///   （`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）。ThisDeviceOnly の
///   item は **バックアップに含まれない**ので、復元先の端末には item が無く、
///   その端末で新しい ID が生成される。`this_device` でない `first_unlock` は
///   バックアップに乗るため、ここでは選べない。`unlocked` 系でなく
///   first_unlock 系なのは、プッシュ登録がロック中のバックグラウンドでも走る
///   ため（PushKeyStore #392 / AccountStorage #643 と同じ理由）。
/// - **Android**: EncryptedSharedPreferences のマスター鍵は Android Keystore に
///   あり、**バックアップされない**。復元先では既存のエントリを復号できず read が
///   失敗するので、その場で作り直す（[_load] の catch）。
/// - **desktop**: Windows は DPAPI（ユーザー + マシン束縛）、Linux は libsecret、
///   macOS は上記 Keychain。いずれもプロファイルのコピーでは復号できない。
///
/// `groupId` は付けない。NSE から読む値ではないうえ、Keychain partition を
/// 変えると既存 item の読み出しに影響しうる（AccountStorage と同じ判断）。
///
/// **旧 ID は移行しない。** SharedPreferences に残っている値を引き継ぐと、
/// 複製された ID がそのまま生き残って #952 が消えない。全端末で 1 度だけ ID が
/// 変わるが、relay はまだ device_id を dedup に使っていない（行のキーは
/// `UNIQUE(token, account, server)`）ので実害がない。旧キーは best-effort で
/// 掃除する。
///
/// なお #932 が書いていた「アンインストールで消えればよい」という寿命は捨てた。
/// iOS の Keychain item はアンインストール後も残るため、再インストールすると
/// 同じ ID に戻る。dedup の要件は「別筐体で別値」であって「再インストールで
/// 別値」ではなく、むしろ行が増えない分だけ望ましい。
class DeviceInstallId {
  DeviceInstallId._();

  @visibleForTesting
  static const storageKey = 'capsicum_device_install_id';

  /// #932 の初版が使っていた SharedPreferences のキー。読みには使わず、
  /// 残骸を消すためだけに参照する（#952）。
  @visibleForTesting
  static const legacyPrefsKey = 'capsicum_device_install_id';

  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  /// 生成レースを塞ぐためのメモ。プッシュ登録はアカウントごとに走るため
  /// [get] は起動直後にほぼ同時多発で呼ばれる。await を挟んで
  /// 「read → 無ければ generate → write」を各々が回すと、後勝ちで別々の ID を
  /// 書き合い、relay 側から見て 1 インストールが複数デバイスに見える。
  /// Future 自体を先に確定させて、以降の呼び出しは同じ Future を待たせる。
  static Future<String>? _pending;

  /// このインストールの ID を返す。未生成なら生成して永続化する。
  static Future<String> get() => _pending ??= _load();

  static Future<String> _load() async {
    String? existing;
    try {
      existing = await _storage.read(key: storageKey);
    } catch (e) {
      // Android の復元直後（マスター鍵が別）や Keychain 一過性失敗。前者は
      // 作り直すのが正解、後者もこの起動では読めないので同じ扱いにする。
      // 一過性で作り直してしまうと relay に行が 1 つ増えるが、恒久的に
      // 復元端末と ID を共有するより害が小さい。
      debugPrint('capsicum: device install id unreadable: $e');
    }
    if (existing != null && existing.isNotEmpty) {
      await _removeLegacyPrefsKey();
      return existing;
    }

    final generated = _generateUuidV4();
    try {
      await _storage.write(key: storageKey, value: generated);
    } catch (e) {
      // 永続化に失敗しても push 登録そのものは従来どおり（token をキーにした
      // 動作）で通したいので、その場限りの値を返して続行する。
      //
      // メモはほどかない。ほどくとアカウントごとに違う ID を送ることになり、
      // relay から 1 インストールが N デバイスに見える。**このプロセス内では
      // 全アカウントが同じ値**を使うほうが害が小さい。永続化のやり直しは
      // 次回起動（新しいプロセス）に任せる。
      debugPrint('capsicum: device install id unavailable: $e');
    }
    await _removeLegacyPrefsKey();
    return generated;
  }

  /// #932 の初版が SharedPreferences に書いた ID を消す。値は引き継がない
  /// （引き継ぐと複製された ID が生き残る）。失敗しても実害はないので握る。
  static Future<void> _removeLegacyPrefsKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(legacyPrefsKey)) {
        await prefs.remove(legacyPrefsKey);
      }
    } catch (e) {
      debugPrint('capsicum: legacy device install id cleanup failed: $e');
    }
  }

  /// テスト間で状態を持ち越さないためのリセット。
  @visibleForTesting
  static void resetForTest() => _pending = null;

  /// RFC 9562 の UUID v4（version / variant ビットを立てた 122 bit 乱数）。
  ///
  /// `uuid` パッケージを足さないのは、capsicum アプリ側の依存に petitparser /
  /// uuid のバージョン衝突の経緯があり（pubspec.yaml のコメント参照）、
  /// この用途は [Random.secure] で完結するため。
  static String _generateUuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}

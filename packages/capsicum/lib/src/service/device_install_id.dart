import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// このインストールを一意に指す ID（#932 / capsicum-relay#15）。
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
/// - **保存先は SharedPreferences**。アプリ更新をまたいで残り、アンインストール
///   で消えればよい、という寿命がちょうど要件と一致する。
///   `flutter_secure_storage` は accessibility 変更で既存 item を取りこぼす罠が
///   あり（docs/tech-notes.md 認証フロー）、機密でもないので使う理由がない。
class DeviceInstallId {
  DeviceInstallId._();

  @visibleForTesting
  static const prefsKey = 'capsicum_device_install_id';

  /// 生成レースを塞ぐためのメモ。プッシュ登録はアカウントごとに走るため
  /// [get] は起動直後にほぼ同時多発で呼ばれる。await を挟んで
  /// 「read → 無ければ generate → write」を各々が回すと、後勝ちで別々の ID を
  /// 書き合い、relay 側から見て 1 インストールが複数デバイスに見える。
  /// Future 自体を先に確定させて、以降の呼び出しは同じ Future を待たせる。
  static Future<String>? _pending;

  /// このインストールの ID を返す。未生成なら生成して永続化する。
  static Future<String> get() => _pending ??= _load();

  static Future<String> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getString(prefsKey);
      if (existing != null && existing.isNotEmpty) return existing;

      final generated = _generateUuidV4();
      await prefs.setString(prefsKey, generated);
      return generated;
    } catch (e) {
      // 永続化に失敗しても push 登録そのものは従来どおり（token をキーにした
      // 動作）で通したいので、その場限りの値を返して続行する。
      //
      // メモはほどかない。ほどくとアカウントごとに違う ID を送ることになり、
      // relay から 1 インストールが N デバイスに見える。**このプロセス内では
      // 全アカウントが同じ値**を使うほうが害が小さい。永続化のやり直しは
      // 次回起動（新しいプロセス）に任せる。
      debugPrint('capsicum: device install id unavailable: $e');
      return _generateUuidV4();
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

import 'package:shared_preferences/shared_preferences.dart';

/// アカウント単位の通知ラベル（「ブースト/リノート/リキュア！」等と「投稿」）を
/// shared_preferences に焼き込むキャッシュ。
///
/// フォアグラウンドでは Riverpod 経由で [MulukhiyaService] の最新値を
/// 直接参照できるが、FCM バックグラウンド isolate では providers が生きて
/// いないため、Account を列挙する経路を持たない。mulukhiya を probe した
/// 時点の解決済みラベルをここに保存しておき、バックグラウンドからは
/// account キー (`username@host`) で lookup する。
///
/// キーは `capsicum_notif_label_{slot}_{account}` 形式。slot は [_Slot] 参照。
class NotificationLabelCache {
  static const _prefix = 'capsicum_notif_label_';
  static const _defaultReblog = 'ブースト';
  static const _defaultPost = '投稿';

  /// [account] は `username@host`。[reblogLabel] / [postLabel] はすでに
  /// 「mulukhiya.reblog_label → adapter 種別」の優先順位で解決済みの
  /// 最終文字列を渡すこと。
  static Future<void> save(
    String account, {
    required String reblogLabel,
    required String postLabel,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(_Slot.reblog, account), reblogLabel);
    await prefs.setString(_key(_Slot.post, account), postLabel);
  }

  /// バックグラウンド isolate から呼ぶ lookup。保存がなければ汎用ラベルを返す。
  static Future<String> readReblog(String account) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key(_Slot.reblog, account)) ?? _defaultReblog;
  }

  static Future<String> readPost(String account) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key(_Slot.post, account)) ?? _defaultPost;
  }

  /// ログアウト時に呼ぶ。該当アカウントのエントリを全削除する。
  static Future<void> remove(String account) async {
    final prefs = await SharedPreferences.getInstance();
    for (final slot in _Slot.values) {
      await prefs.remove(_key(slot, account));
    }
  }

  static String _key(_Slot slot, String account) =>
      '$_prefix${slot.fragment}_$account';
}

enum _Slot {
  reblog('reblog'),
  post('post');

  final String fragment;
  const _Slot(this.fragment);
}

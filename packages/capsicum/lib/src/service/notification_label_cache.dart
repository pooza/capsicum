import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_foundation/shared_preferences_foundation.dart';

/// アカウント単位の通知ラベル（「ブースト/リノート/リキュア！」等と「投稿」）を
/// プラットフォームごとに適切な永続化先へ焼くキャッシュ。
///
/// フォアグラウンドでは Riverpod 経由で [MulukhiyaService] の最新値を
/// 直接参照できるが、FCM バックグラウンド isolate や iOS Notification
/// Service Extension は providers が生きていないため、Account を列挙する
/// 経路を持たない。mulukhiya を probe した時点の解決済みラベルをここに
/// 保存しておき、account キー (`username@host`) で lookup する。
///
/// 永続化先:
/// - iOS/macOS: [SharedPreferencesAsync] + App Group suiteName
///   (`group.jp.co.b-shock.capsicum`)。NSE からも
///   `UserDefaults(suiteName:)` で同一のキーを読める。
/// - Android / その他: 通常の [SharedPreferencesAsync]（DataStore backend）。
///   FCM バックグラウンド isolate は firebase_messaging の仕組みで
///   `DartPluginRegistrant.ensureInitialized()` が呼ばれるため同じ
///   shared_preferences API がそのまま使える。
///
/// キーは `capsicum_notif_label_{slot}_{account}` 形式。slot は [_Slot] 参照。
class NotificationLabelCache {
  /// iOS の App Group 識別子。Runner / ShareExtension / NSE の
  /// entitlements と一致させる必要がある。
  static const appGroupId = 'group.jp.co.b-shock.capsicum';
  static const _prefix = 'capsicum_notif_label_';
  static const _defaultReblog = 'ブースト';
  static const _defaultPost = '投稿';

  static SharedPreferencesAsync _prefs() => SharedPreferencesAsync(
    options: Platform.isIOS || Platform.isMacOS
        ? SharedPreferencesAsyncFoundationOptions(suiteName: appGroupId)
        : const SharedPreferencesOptions(),
  );

  /// [account] は `username@host`。[reblogLabel] / [postLabel] はすでに
  /// 「mulukhiya.reblog_label → adapter 種別」の優先順位で解決済みの
  /// 最終文字列を渡すこと。
  static Future<void> save(
    String account, {
    required String reblogLabel,
    required String postLabel,
  }) async {
    final prefs = _prefs();
    await prefs.setString(_key(_Slot.reblog, account), reblogLabel);
    await prefs.setString(_key(_Slot.post, account), postLabel);
  }

  /// バックグラウンド isolate から呼ぶ lookup。保存がなければ汎用ラベルを返す。
  static Future<String> readReblog(String account) async {
    return (await _prefs().getString(_key(_Slot.reblog, account))) ??
        _defaultReblog;
  }

  static Future<String> readPost(String account) async {
    return (await _prefs().getString(_key(_Slot.post, account))) ??
        _defaultPost;
  }

  /// ログアウト時に呼ぶ。該当アカウントのエントリを全削除する。
  static Future<void> remove(String account) async {
    final prefs = _prefs();
    for (final slot in _Slot.values) {
      await prefs.remove(_key(slot, account));
    }
  }

  /// 複数のアカウントでログインしているか (#1407)。
  ///
  /// 復号できたプッシュの見出しに宛先のアカウントを添えるかを、FCM の
  /// バックグラウンド isolate と iOS / macOS の NSE が決めるために読む。
  /// デスクトップの WebSocket 経路（`desktop_notification_dispatcher.dart`）と同じく、
  /// **1 アカウントだけなら添えない**（冗長なため・#675 の線）。
  ///
  /// ⚠ キーは NSE の `MultiAccountFlag`（`NotificationService.swift`）と揃えること。
  static const multiAccountKey = '${_prefix}multi_account';

  /// ⚠ `async` を外さない。外すと、プラットフォームが無いとき（テスト等）に
  /// `_prefs()` が同期で投げ、呼び出し側の `catchError` を素通りする。
  static Future<void> saveMultiAccount(bool value) async {
    await _prefs().setBool(multiAccountKey, value);
  }

  /// 保存が無ければ false（宛先を添えない＝従来どおり）。
  static Future<bool> readMultiAccount() async =>
      (await _prefs().getBool(multiAccountKey)) ?? false;

  static String _key(_Slot slot, String account) =>
      '$_prefix${slot.fragment}_$account';
}

/// 復号できたプッシュの見出しに、宛先のアカウントを添える (#1407)。
///
/// 形はデスクトップの WebSocket 経路（`DesktopNotificationDispatcher._title`）と
/// 揃えて `見出し (@user@host)`。[account] は relay の `username@host`。
/// ⚠ NSE の `NotificationService.titleWithRecipient` と同じ形にすること。
String titleWithRecipient(
  String title,
  String account, {
  required bool multiAccount,
}) {
  if (!multiAccount || account.isEmpty) return title;
  return '$title (@$account)';
}

enum _Slot {
  reblog('reblog'),
  post('post');

  final String fragment;
  const _Slot(this.fragment);
}

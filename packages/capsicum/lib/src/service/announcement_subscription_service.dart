import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../model/account.dart';
import '../util/exception_scrub.dart';
import 'push_key_store.dart';
import 'push_relay_client.dart';

/// お知らせ通知 (#477) の subscription を管理するサービス。
///
/// capsicum-relay#14 の `POST /announcement_subscriptions` で登録した
/// id を SharedPreferences に保存し、ユーザーがトグルを OFF にしたとき
/// `DELETE /announcement_subscriptions/:id` で解除する。
///
/// セマンティクスは「**デフォルト ON / 明示 OFF を記録**」の opt-out モデル。
/// 自前サーバーのアナウンスを聞き逃して欲しくない意図 (pooza の要望) で、
/// features.announcement_push 対応サーバーに対しては
/// [autoEnableIfDefault] が registerAccount 後に自動で enable する。
///
/// 前提として親 push subscription ([PushRegistrationService.registerAccount]
/// が完了した状態) と保存済み endpoint が必要。relay 側 FK の関係で
/// 親が無いと 404 が返る。
class AnnouncementSubscriptionService {
  /// アカウント別 subscription id 保存先 (SharedPreferences key prefix)。
  /// 値の型は int。存在 = 有効、不在 = 無効。
  @visibleForTesting
  static const prefsKeyPrefix = 'capsicum_announcement_sub_';

  /// 明示的に OFF にしたかを記録する marker (SharedPreferences key prefix)。
  /// 値は単に true を入れる。存在 = 明示 OFF (auto-enable しない)、不在 =
  /// 未操作 (auto-enable 対象)。
  @visibleForTesting
  static const prefsKeyOptOutPrefix = 'capsicum_announcement_optout_';

  static PushRelayClient _client = PushRelayClient();

  /// 単体テストから差し替えるための注入点。
  @visibleForTesting
  static set client(PushRelayClient client) {
    _client = client;
  }

  /// テストがホスト OS に依存せず分岐を通すための override。
  @visibleForTesting
  static bool? debugPlatformSupportedOverride;

  /// お知らせ push を購読するプラットフォームか。
  ///
  /// relay の AnnouncementWorker は device_type が ios / android のときだけ
  /// 配送し、macos は配送しない。macOS はアプリ起動中のお知らせを WebSocket
  /// 経路 (#569) がリッチ通知で出すうえ、非起動時の取りこぼしはアプリ内の
  /// お知らせ画面で読めるため、push 購読は mobile 限定とする
  /// (docs/desktop-notification-design.md の #673 節)。設定画面のトグル表示
  /// 判定にも使う。
  static bool get platformSupported =>
      debugPlatformSupportedOverride ??
      (!kIsWeb && (Platform.isIOS || Platform.isAndroid));

  /// 指定アカウントが announcement push に opt-in 済みか。
  static Future<bool> isEnabled(String accountStorageKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('$prefsKeyPrefix$accountStorageKey');
  }

  /// 明示的に OFF にされているか (auto-enable をブロックするマーカー)。
  static Future<bool> isExplicitlyOptedOut(String accountStorageKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('$prefsKeyOptOutPrefix$accountStorageKey') ?? false;
  }

  /// ローカルに subscription id か opt-out marker のいずれかが残っているか。
  /// 設定画面の opt-out トグル表示判定に使う — register snapshot が registered
  /// でなくても、relay 側 subscription が active なら OFF にする経路を保つ。
  static Future<bool> hasLocalState(String accountStorageKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('$prefsKeyPrefix$accountStorageKey') ||
        prefs.containsKey('$prefsKeyOptOutPrefix$accountStorageKey');
  }

  /// 登録未済かつ明示 OFF でもないアカウントを、サーバー側が
  /// features.announcement_push をサポートしていれば自動的に enable する。
  /// registerAccount 成功直後に呼び出され、デフォルト ON 化を実現する。
  ///
  /// 失敗時もログ + Sentry に流すだけで本筋 (push registration) は止めない。
  static Future<void> autoEnableIfDefault(Account account) async {
    final accountStorageKey = account.key.toStorageKey();
    if (!platformSupported) {
      // 非対応プラットフォーム (macOS 等)。過去の自動購読が残っていれば
      // 片付ける — relay には配送されない死に subscription のため。
      // opt-out marker はユーザー意思の記録なので触らない。
      if (await isEnabled(accountStorageKey)) {
        await disable(accountStorageKey, host: account.key.host);
      }
      return;
    }
    if (account.mulukhiya?.announcementPushEnabled != true) return;
    if (await isExplicitlyOptedOut(accountStorageKey)) return;
    if (await isEnabled(accountStorageKey)) return;
    try {
      await enable(account);
    } catch (e) {
      // enable 内で Sentry 報告済み。本筋は止めない。
      debugPrint(
        'capsicum: announcement_subscription: auto-enable skipped for '
        '${account.key.host}: $e',
      );
    }
  }

  /// アカウントの announcement push を有効化する。
  ///
  /// 親 push subscription ([PushKeyStore.getEndpoint] が値を返す状態) が
  /// 必要。なければ [StateError] を投げる。relay 応答の `id` を
  /// SharedPreferences に保存する。
  static Future<void> enable(Account account) async {
    final accountStorageKey = account.key.toStorageKey();
    final endpoint = await PushKeyStore.getEndpoint(accountStorageKey);
    if (endpoint == null) {
      throw StateError(
        'announcement_subscription: no push endpoint for $accountStorageKey '
        '(call PushRegistrationService.registerAccount first)',
      );
    }
    final pushToken = _extractPushToken(endpoint);
    if (pushToken == null) {
      throw StateError(
        'announcement_subscription: cannot extract push_token from endpoint',
      );
    }

    try {
      final result = await _client.registerAnnouncementSubscription(
        pushToken: pushToken,
        account: '${account.key.username}@${account.key.host}',
        server: account.key.host,
      );
      final id = PushRelayClient.parseRelayId(result['id']);
      if (id == null) {
        throw StateError(
          'announcement_subscription: relay response missing id',
        );
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('$prefsKeyPrefix$accountStorageKey', id);
      // 過去に明示 OFF にしていた場合の marker を解除 — 再 ON で
      // auto-enable が将来また通せるようにする。
      await prefs.remove('$prefsKeyOptOutPrefix$accountStorageKey');
      debugPrint(
        'capsicum: announcement_subscription: enabled '
        '${account.key.username}@${account.key.host} (id=$id)',
      );
    } catch (e, st) {
      _captureFailure(e, st, account.key.host, phase: 'enable');
      rethrow;
    }
  }

  /// アカウントの announcement push を無効化する。
  ///
  /// 保存済み id があれば relay に DELETE を投げ、SharedPreferences の
  /// 該当キーを削除する。relay 側エラーは log + Sentry に流し本筋は止めない
  /// (ローカル削除は必ず行う = ユーザーから見て OFF になる)。
  ///
  /// [explicit] が true の場合は opt-out marker を立て、以降の
  /// [autoEnableIfDefault] でも自動 ON されないようにする。ログアウト等の
  /// システム経路では false を渡し、ユーザーの再ログイン時に default ON
  /// を継続できるようにする。
  static Future<void> disable(
    String accountStorageKey, {
    String? host,
    bool explicit = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getInt('$prefsKeyPrefix$accountStorageKey');
    await prefs.remove('$prefsKeyPrefix$accountStorageKey');
    if (explicit) {
      await prefs.setBool('$prefsKeyOptOutPrefix$accountStorageKey', true);
    }
    if (id == null) return;
    try {
      await _client.unregisterAnnouncementSubscription(id);
      debugPrint(
        'capsicum: announcement_subscription: disabled '
        '$accountStorageKey (id=$id, explicit=$explicit)',
      );
    } catch (e, st) {
      _captureFailure(e, st, host ?? '(unknown)', phase: 'disable');
    }
  }

  /// endpoint URL (`https://relay.capsicum.shrieker.net/push/<token>`) から
  /// device-scoped push_token を取り出す。スキーマ違反時は null。
  static String? _extractPushToken(String endpoint) {
    final lastSlash = endpoint.lastIndexOf('/');
    if (lastSlash < 0 || lastSlash == endpoint.length - 1) return null;
    return endpoint.substring(lastSlash + 1);
  }

  static void _captureFailure(
    Object e,
    StackTrace st,
    String host, {
    required String phase,
  }) {
    debugPrint(
      'capsicum: announcement_subscription: $phase failed for $host: $e',
    );
    Sentry.captureException(
      scrubException(e),
      stackTrace: st,
      withScope: (scope) {
        scope.setTag('service', 'announcement_subscription');
        scope.setTag('phase', phase);
        scope.setTag('push.host', host);
        scope.fingerprint = [
          'announcement_subscription',
          phase,
          e.runtimeType.toString(),
        ];
      },
    );
  }
}

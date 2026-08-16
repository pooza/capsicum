import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../model/account.dart';
import '../util/exception_scrub.dart';
import 'push_device_type.dart';
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
  /// **relay の [AnnouncementWorker#deliver] が配る device_type と 1 対 1 で
  /// 揃える**。ここが広いと「登録できるのに届かない」死に subscription を作り、
  /// 狭いと「届くのに購読できない」。設定画面のトグル表示判定にも使う。
  ///
  /// macOS は capsicum-relay#36 Phase 1 (relay `0530a9a`) で配送対象に入った
  /// ので含める。iOS と同一 Bundle ID・同一 APNs Auth Key で送れ、NSE は
  /// `body` / `encoding` を持たない push を早期 guard で素通しするため、relay が
  /// 付けた `aps.alert` がそのまま表示される (capsicum-relay#17 で実測)。
  /// **client 側に受信の作り込みは要らない** (#919)。
  ///
  /// Windows は #978 で bg task 側の経路が入ったので含める。WNS raw push には
  /// `aps.alert` に相当する OS 側の表示機構が無いため、macOS と違って
  /// **client 側の作り込みが要る** — bg task が `notification_type:
  /// "announcement"` のエンベロープを解釈し、relay が整形した
  /// `announcement_body` でトーストを組む。Linux はネイティブ push の経路
  /// 自体が無い (#475)。
  ///
  /// 非対応プラットフォーム (Linux) でも、アプリ**起動中**のお知らせは
  /// WebSocket 経路 (#569) が拾って OS 通知に出す。設定画面はトグルの代わりに
  /// その旨を説明する ([resolveAnnouncementRow])。
  static bool get platformSupported =>
      debugPlatformSupportedOverride ??
      deliverableDeviceTypes.contains(currentPushDeviceType);

  /// relay の `AnnouncementWorker#deliver` が実際に配送する device_type。
  /// [platformSupported] の実体で、**relay 側の `case` と 1 対 1 に保つ**。
  ///
  /// ⚠ `windows` を含める以上、**relay#36 Phase 2 (`when 'windows'` +
  /// `announcement_body`) を v1.57 の Windows 出荷までにデプロイしておく**
  /// こと。デプロイ順はどちらが先でも壊れない — 現行 (v1.56 以前) の Windows
  /// クライアントはこのゲートに阻まれて announcement subscription を 1 行も
  /// 作っていないので、relay を先に広げても送る先が無い。
  @visibleForTesting
  static const deliverableDeviceTypes = {'ios', 'android', 'macos', 'windows'};

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
      // 非対応プラットフォーム (Linux)。過去の自動購読が残っていれば
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

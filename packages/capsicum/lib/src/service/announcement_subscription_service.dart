import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../model/account.dart';
import 'exception_scrub.dart';
import 'push_key_store.dart';
import 'push_relay_client.dart';

/// お知らせ通知 (#477) の subscription を管理するサービス。
///
/// capsicum-relay#14 の `POST /announcement_subscriptions` で登録した
/// id を SharedPreferences に保存し、ユーザーがトグルを OFF にしたとき
/// `DELETE /announcement_subscriptions/:id` で解除する。
///
/// 前提として親 push subscription ([PushRegistrationService.registerAccount]
/// が完了した状態) と保存済み endpoint が必要。relay 側 FK の関係で
/// 親が無いと 404 が返る。
class AnnouncementSubscriptionService {
  /// アカウント別 subscription id 保存先 (SharedPreferences key prefix)。
  /// 値の型は int。存在 = 有効、不在 = 無効。
  @visibleForTesting
  static const prefsKeyPrefix = 'capsicum_announcement_sub_';

  static PushRelayClient _client = PushRelayClient();

  /// 単体テストから差し替えるための注入点。
  @visibleForTesting
  static set client(PushRelayClient client) {
    _client = client;
  }

  /// 指定アカウントが announcement push に opt-in 済みか。
  static Future<bool> isEnabled(String accountStorageKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('$prefsKeyPrefix$accountStorageKey');
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
      final id = _parseRelayId(result['id']);
      if (id == null) {
        throw StateError(
          'announcement_subscription: relay response missing id',
        );
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('$prefsKeyPrefix$accountStorageKey', id);
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
  static Future<void> disable(String accountStorageKey, {String? host}) async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getInt('$prefsKeyPrefix$accountStorageKey');
    await prefs.remove('$prefsKeyPrefix$accountStorageKey');
    if (id == null) return;
    try {
      await _client.unregisterAnnouncementSubscription(id);
      debugPrint(
        'capsicum: announcement_subscription: disabled '
        '$accountStorageKey (id=$id)',
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

  /// relay 応答の `id` は int / 数値文字列の両方を許容する。
  /// [PushRegistrationService._parseRelayId] と同仕様。
  static int? _parseRelayId(Object? raw) {
    if (raw is int) return raw;
    if (raw == null) return null;
    return int.tryParse(raw.toString());
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

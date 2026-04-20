import 'dart:io';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/foundation.dart';

import '../model/account.dart';
import 'apns_service.dart';
import 'push_key_store.dart';
import 'push_relay_client.dart';

/// プッシュ通知のリレーサーバー登録と Web Push サブスクリプション登録を
/// オーケストレーションするサービス。
///
/// 登録フロー:
/// 1. デバイストークン取得（APNs / FCM）
/// 2. リレーサーバーにデバイストークンを登録 → push_token を取得
/// 3. ECDH P-256 鍵ペアを生成（または既存鍵をロード）
/// 4. Mastodon / Misskey に Web Push サブスクリプションを登録
///    （エンドポイント = リレーサーバーの /push/{push_token}）
///
/// プリセットサーバーのアカウントのみ登録する。失敗してもアプリの動作には
/// 影響しない（ベストエフォート）。
class PushRegistrationService {
  static const _presetServers = {
    'mstdn.b-shock.org',
    'mstdn.delmulin.com',
    'precure.ml',
    'mk.precure.fun',
    'misskey.delmulin.com',
  };

  static final _client = PushRelayClient();

  /// 単一アカウントのプッシュ通知登録を行う。
  static Future<void> registerAccount(Account account) async {
    try {
      if (account.adapter is! PushSubscriptionSupport) return;
      if (!_presetServers.contains(account.key.host)) return;

      final deviceToken = _getDeviceToken();
      if (deviceToken == null) {
        debugPrint('PushRegistration: no device token available');
        return;
      }

      final deviceType = Platform.isIOS ? 'ios' : 'android';
      final accountKey = account.key.toStorageKey();

      // リレーサーバーに登録
      final sub = await _client.register(
        token: deviceToken,
        deviceType: deviceType,
        account: '${account.key.username}@${account.key.host}',
        server: account.key.host,
      );

      final relayId = sub['id'] as int;
      final pushToken = sub['push_token'] as String?;
      if (pushToken == null) {
        debugPrint('PushRegistration: relay returned no push_token');
        return;
      }

      await PushKeyStore.saveRelayId(accountKey, relayId);

      // ECDH 鍵の生成またはロード
      final keys = await PushKeyStore.getOrCreate(accountKey);

      // Mastodon / Misskey に Web Push サブスクリプション登録
      final endpoint = '${PushRelayClient.relayBaseUrl}/push/$pushToken';
      await (account.adapter as PushSubscriptionSupport).subscribePush(
        endpoint: endpoint,
        p256dh: keys.p256dh,
        auth: keys.auth,
      );

      debugPrint(
        'PushRegistration: registered ${account.key.username}@${account.key.host}',
      );
    } catch (e) {
      debugPrint('PushRegistration: failed for ${account.key.host}: $e');
    }
  }

  /// 単一アカウントのプッシュ通知登録を解除する。
  static Future<void> unregisterAccount(Account account) async {
    try {
      if (account.adapter is PushSubscriptionSupport) {
        await (account.adapter as PushSubscriptionSupport).unsubscribePush();
      }

      final accountKey = account.key.toStorageKey();
      final relayId = await PushKeyStore.getRelayId(accountKey);
      if (relayId != null) {
        await _client.unregister(relayId);
      }

      await PushKeyStore.delete(accountKey);
    } catch (e) {
      debugPrint('PushRegistration: unregister failed: $e');
    }
  }

  /// 全アカウントのプッシュ通知登録を行う（アプリ起動時に呼ぶ）。
  static Future<void> registerAllAccounts(List<Account> accounts) async {
    for (final account in accounts) {
      await registerAccount(account);
    }
  }

  static String? _getDeviceToken() {
    if (Platform.isIOS) return ApnsService.deviceToken;
    // Android: FCM トークン取得は #315 で実装
    return null;
  }
}

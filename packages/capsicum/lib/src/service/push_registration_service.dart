import 'dart:async';
import 'dart:io';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../model/account.dart';
import 'apns_service.dart';
import 'fcm_service.dart';
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
/// プリセットサーバーのアカウントを1つでも持っていれば、全アカウントを
/// 登録対象とする。失敗してもアプリの動作には影響しない（ベストエフォート）。
class PushRegistrationService {
  static const _presetServers = {
    'mstdn.b-shock.org',
    'mstdn.delmulin.com',
    'precure.ml',
    'mk.precure.fun',
    'misskey.delmulin.com',
    // ステージング
    'st.mstdn.b-shock.org',
    'st2.mstdn.delmulin.com',
    'st.precure.ml',
    'st.misskey.delmulin.com',
  };

  /// 指定ホストがプリセットサーバーかどうかを判定する。
  static bool isPresetServer(String host) => _presetServers.contains(host);

  static final _client = PushRelayClient();

  static StreamSubscription<String>? _tokenRefreshSub;

  /// 単一アカウントのプッシュ通知登録を行う。
  ///
  /// [eligible] が true の場合、プリセット判定をスキップして登録する。
  /// [registerAllAccounts] から呼ばれるときに使用。
  static Future<void> registerAccount(
    Account account, {
    bool eligible = false,
  }) async {
    try {
      if (account.adapter is! PushSubscriptionSupport) return;
      if (!eligible && !_presetServers.contains(account.key.host)) {
        debugPrint(
          'PushRegistration: skipped (not preset): ${account.key.host}',
        );
        return;
      }

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

      final relayId = _parseRelayId(sub['id']);
      final pushToken = sub['push_token'] as String?;
      if (relayId == null || pushToken == null) {
        debugPrint('PushRegistration: relay response missing fields: $sub');
        _captureContractViolation(
          'relay register response missing id/push_token',
          account.key.host,
        );
        return;
      }

      await PushKeyStore.saveRelayId(accountKey, relayId);

      // ECDH 鍵の生成またはロード
      final keys = await PushKeyStore.getOrCreate(accountKey);

      // Mastodon / Misskey に Web Push サブスクリプション登録
      final endpoint = '${PushRelayClient.relayBaseUrl}/push/$pushToken';
      // endpoint を先に永続化しておくことで、subscribePush が 4xx で失敗した
      // 場合でも unregisterAccount で Misskey 側の掃除を試みられる。
      await PushKeyStore.saveEndpoint(accountKey, endpoint);
      await (account.adapter as PushSubscriptionSupport).subscribePush(
        endpoint: endpoint,
        p256dh: keys.p256dh,
        auth: keys.auth,
      );

      debugPrint(
        'PushRegistration: registered ${account.key.username}@${account.key.host}',
      );
    } catch (e, st) {
      debugPrint('PushRegistration: failed for ${account.key.host}: $e\n$st');
      if (!_isTransient(e)) {
        Sentry.captureException(
          _scrubException(e),
          stackTrace: st,
          withScope: (scope) {
            scope.setTag('service', 'push_registration');
            scope.setTag('host', account.key.host);
          },
        );
      }
    }
  }

  /// 単一アカウントのプッシュ通知登録を解除する。
  ///
  /// 各段階（SNS サーバーの unsubscribe / リレー unregister / ローカル鍵削除）
  /// は独立に try する。上流の段階が失敗しても後続の掃除を止めないことで、
  /// 孤立サブスクリプション・鍵残留を最小化する。
  static Future<void> unregisterAccount(Account account) async {
    final accountKey = account.key.toStorageKey();

    if (account.adapter is PushSubscriptionSupport) {
      try {
        final endpoint = await PushKeyStore.getEndpoint(accountKey);
        await (account.adapter as PushSubscriptionSupport).unsubscribePush(
          endpoint: endpoint,
        );
      } catch (e, st) {
        debugPrint('PushRegistration: adapter unsubscribe failed: $e');
        _reportUnregisterFailure(e, st, account.key.host, 'adapter');
      }
    }

    try {
      final relayId = await PushKeyStore.getRelayId(accountKey);
      if (relayId != null) {
        await _client.unregister(relayId);
      }
    } catch (e, st) {
      debugPrint('PushRegistration: relay unregister failed: $e');
      _reportUnregisterFailure(e, st, account.key.host, 'relay');
    }

    try {
      await PushKeyStore.delete(accountKey);
    } catch (e, st) {
      debugPrint('PushRegistration: keystore delete failed: $e');
      _reportUnregisterFailure(e, st, account.key.host, 'keystore');
    }
  }

  static void _reportUnregisterFailure(
    Object e,
    StackTrace st,
    String host,
    String stage,
  ) {
    if (_isTransient(e)) return;
    Sentry.captureException(
      _scrubException(e),
      stackTrace: st,
      withScope: (scope) {
        scope.setTag('service', 'push_registration');
        scope.setTag('phase', 'unregister');
        scope.setTag('stage', stage);
        scope.setTag('host', host);
      },
    );
  }

  /// デバイストークンのローテーションを監視し、検知したら全アカウントを
  /// 再登録する。
  ///
  /// アプリ起動時に1度呼ぶ。ストリームはブロードキャストで過去の emit を
  /// 配信しないため、初回登録（[registerAllAccounts]）と重複して発火する
  /// ことはなく、以降の本物のローテーションのみに反応する。
  ///
  /// [getAccounts] は発火時点の最新アカウント一覧を返す。起動時点の値で
  /// 固定するとログアウト済みアカウントまで再登録する事故になるため、
  /// コールバックを渡す設計にしている。
  static void startTokenRefreshListener(List<Account> Function() getAccounts) {
    _tokenRefreshSub?.cancel();
    final Stream<String>? stream;
    if (Platform.isIOS) {
      stream = ApnsService.onTokenChanged;
    } else if (Platform.isAndroid) {
      stream = FcmService.onTokenChanged;
    } else {
      return;
    }
    _tokenRefreshSub = stream.listen((_) async {
      debugPrint('PushRegistration: device token rotated, re-registering');
      final accounts = getAccounts();
      if (accounts.isEmpty) return;
      // 古いリレー登録・SNS サブスクリプション・鍵を掃除してから登録し直す。
      // 新しいトークンで POST /register すると、そのままではリレー DB に
      // 孤立レコードと古い SNS サブスクリプションが残るため unregister を
      // 先に流す。unregister は各段階が独立なので部分失敗しても問題ない。
      for (final account in accounts) {
        await unregisterAccount(account);
      }
      await registerAllAccounts(accounts);
    });
  }

  /// 全アカウントのプッシュ通知登録を行う（アプリ起動時に呼ぶ）。
  ///
  /// プリセットサーバーのアカウントが1つでもあれば、全アカウントを登録対象とする。
  /// デバイストークンが未取得の場合は到着を待ってから登録する。
  static Future<void> registerAllAccounts(List<Account> accounts) async {
    if (accounts.isEmpty) return;

    // デバイストークンが未取得なら到着を待つ（最大 10 秒）
    if (_getDeviceToken() == null) {
      final token = await _waitForDeviceToken();
      if (token == null) {
        debugPrint('PushRegistration: device token not available, skipping');
        return;
      }
    }

    final hasPreset = accounts.any((a) => _presetServers.contains(a.key.host));
    for (final account in accounts) {
      await registerAccount(account, eligible: hasPreset);
    }
  }

  /// デバイストークンの到着を最大 10 秒待つ。
  static Future<String?> _waitForDeviceToken() async {
    if (Platform.isIOS) {
      return ApnsService.onTokenChanged.first
          .timeout(const Duration(seconds: 10), onTimeout: () => '')
          .then((t) => t.isEmpty ? null : t);
    }
    if (Platform.isAndroid) {
      return FcmService.onTokenChanged.first
          .timeout(const Duration(seconds: 10), onTimeout: () => '')
          .then((t) => t.isEmpty ? null : t);
    }
    return null;
  }

  static String? _getDeviceToken() {
    if (Platform.isIOS) return ApnsService.deviceToken;
    if (Platform.isAndroid) return FcmService.deviceToken;
    return null;
  }

  /// リレー応答の `id` を防御的にパースする。整数・数値文字列の両方を許容し、
  /// 解釈不能なら null を返す（呼び出し側で契約違反として計装する）。
  static int? _parseRelayId(Object? raw) {
    if (raw is int) return raw;
    if (raw == null) return null;
    return int.tryParse(raw.toString());
  }

  /// ネットワーク瞬断など通常の運用で発生しうる一過性エラーかどうか。
  /// 一過性は Sentry に送らず、バグや契約違反のみに集中する。
  static bool _isTransient(Object e) {
    if (e is SocketException) return true;
    if (e is TimeoutException) return true;
    if (e is DioException) {
      return e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionError;
    }
    return false;
  }

  /// DioException は `requestOptions.headers` に `X-Relay-Secret` や
  /// body に token を抱えており、そのまま Sentry に投げると漏洩する。
  /// メタ情報のみを抜き出した安全な例外に詰め替える。
  ///
  /// `message` は Dio の版次第で requestOptions.uri を埋め込むケースがあり、
  /// リレー URL には push_token が含まれるため使わず、type とステータス
  /// コードとパスのみを出力する（クエリ文字列はクライアント側で付けて
  /// いないが念のため削ぎ落とす）。
  static Object _scrubException(Object e) {
    if (e is DioException) {
      final path = e.requestOptions.path.split('?').first;
      return StateError(
        'DioException ${e.type.name} '
        'status=${e.response?.statusCode ?? '-'} '
        'path=$path',
      );
    }
    return e;
  }

  /// リレー応答がスキーマを満たさないなど、サーバー契約違反を Sentry に記録する。
  static void _captureContractViolation(String message, String host) {
    Sentry.captureException(
      StateError(message),
      withScope: (scope) {
        scope.setTag('service', 'push_registration');
        scope.setTag('type', 'contract_violation');
        scope.setTag('host', host);
      },
    );
  }
}

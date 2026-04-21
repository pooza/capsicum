import 'dart:async';
import 'dart:io';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../constants.dart';
import '../model/account.dart';
import '../preset_servers.dart';
import 'apns_service.dart';
import 'fcm_service.dart';
import 'push_key_store.dart';
import 'push_registration_status.dart';
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
  /// 指定ホストがプリセットサーバーかどうかを判定する。
  static bool isPresetServer(String host) => kPresetServerHosts.contains(host);

  /// アカウント群の中にプリセットサーバーのアカウントが 1 件以上あるか判定する。
  /// eligible 判定（「連れて登録」判定）の中央集約。
  static bool hasPresetAmong(Iterable<Account> accounts) =>
      accounts.any((a) => isPresetServer(a.key.host));

  static final _client = PushRelayClient();

  static StreamSubscription<String>? _tokenRefreshSub;

  /// アカウント単位の登録処理を排他するための in-flight ガード。
  ///
  /// splash の [registerAllAccounts] ループと `AccountManagerNotifier` 経由の
  /// ログイン時 [registerAccount] 呼び出しが並走した場合に、同一アカウントを
  /// 二重登録してリレー DB に孤立 row を作ってしまう race を避ける。
  static final Map<String, Future<void>> _inFlight = {};

  /// 単一アカウントのプッシュ通知登録を行う。
  ///
  /// [eligible] が true の場合、プリセット判定をスキップして登録する。
  /// [registerAllAccounts] から呼ばれるときに使用。
  ///
  /// 同一アカウントへの並走呼び出しは in-flight ガードで直列化する。
  static Future<void> registerAccount(
    Account account, {
    bool eligible = false,
  }) {
    final key = account.key.toStorageKey();
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final future = _registerAccountImpl(account, eligible: eligible);
    _inFlight[key] = future;
    return future.whenComplete(() => _inFlight.remove(key));
  }

  static Future<void> _registerAccountImpl(
    Account account, {
    required bool eligible,
  }) async {
    final accountKey = account.key.toStorageKey();
    final store = PushRegistrationStatusStore.instance;
    int? relayId;
    // subscribePush が走り始めたことを示すフラグ。catch 節で「失敗の内訳が
    // リレー段か SNS サブスクリプション段か」の判定に使う。
    var subscribePhase = false;
    // PushKeyStore を今回の attempt で書き換えたかどうか。書き換える前の
    // 早期失敗（リレー接続エラー等）では、既存の working state を残しておく
    // 必要がある（wipe すると古いサーバー側サブスクリプションが orphan 化）。
    var localStateModified = false;
    try {
      if (account.adapter is! PushSubscriptionSupport) {
        store.update(accountKey, PushRegistrationState.skipped);
        return;
      }
      if (!eligible && !isPresetServer(account.key.host)) {
        debugPrint(
          'capsicum: push.registration: skipped (not preset): ${account.key.host}',
        );
        store.update(accountKey, PushRegistrationState.skipped);
        return;
      }

      store.update(accountKey, PushRegistrationState.registering);

      final deviceToken = _getDeviceToken();
      if (deviceToken == null) {
        debugPrint('capsicum: push.registration: no device token available');
        final isPermissionDenied = _isNotificationPermissionDenied();
        store.update(
          accountKey,
          PushRegistrationState.failed,
          reason: isPermissionDenied
              ? PushRegistrationFailureReason.permissionDenied
              : PushRegistrationFailureReason.noDeviceToken,
          errorMessage: isPermissionDenied
              ? '通知の権限が許可されていません'
              : 'デバイストークンを取得できませんでした',
        );
        return;
      }

      final deviceType = Platform.isIOS ? 'ios' : 'android';

      // リレーサーバーに登録
      final sub = await _client.register(
        token: deviceToken,
        deviceType: deviceType,
        account: '${account.key.username}@${account.key.host}',
        server: account.key.host,
      );

      relayId = _parseRelayId(sub['id']);
      final pushToken = sub['push_token'] as String?;
      if (relayId == null || pushToken == null) {
        debugPrint(
          'capsicum: push.registration: relay response missing fields: $sub',
        );
        _captureContractViolation(
          'relay register response missing id/push_token',
          account.key.host,
        );
        store.update(
          accountKey,
          PushRegistrationState.failed,
          reason: PushRegistrationFailureReason.relayFailed,
          errorMessage: 'リレーサーバー応答に id / push_token が含まれていません',
        );
        return;
      }

      // ここから PushKeyStore を書き換える。失敗時は rollback 対象になる。
      await PushKeyStore.saveRelayId(accountKey, relayId);
      localStateModified = true;

      // ECDH 鍵の生成またはロード（既存鍵があれば再利用）
      final keys = await PushKeyStore.getOrCreate(accountKey);

      // Mastodon / Misskey に Web Push サブスクリプション登録
      final endpoint = '${PushRelayClient.relayBaseUrl}/push/$pushToken';
      // endpoint を先に永続化しておくことで、subscribePush が 4xx で失敗した
      // 場合でも unregisterAccount で Misskey 側の掃除を試みられる。
      await PushKeyStore.saveEndpoint(accountKey, endpoint);
      subscribePhase = true;
      await (account.adapter as PushSubscriptionSupport).subscribePush(
        endpoint: endpoint,
        p256dh: keys.p256dh,
        auth: keys.auth,
      );

      debugPrint(
        'capsicum: push.registration: registered ${account.key.username}@${account.key.host}',
      );
      store.update(accountKey, PushRegistrationState.registered);
    } catch (e, st) {
      debugPrint(
        'capsicum: push.registration: failed for ${account.key.host}: $e\n$st',
      );
      // NB: 以前はここで `_client.unregister(relayId)` を呼んで relay row を
      // 掃除していたが、これは重大なバグだった。relay schema は UNIQUE(token)
      // で **1 デバイス = 1 row** のため、N アカウントを同時登録すると
      // 全員が同じ relay row (同じ relayId / push_token) を共有する。
      // 1 アカウントの subscribePush が失敗したときに unregister すると、
      // **他の全アカウントが使っている endpoint を巻き添えで破壊** し、
      // Mastodon から push が来ても relay が 404 を返し、subscription が
      // destroy される連鎖が起きる。relay row の寿命は device-scoped なので、
      // 登録フェーズの失敗では触らない。掃除は unregisterAccount 経由の
      // 明示的なログアウト時のみに任せる。
      // PushKeyStore は今回の attempt で書き換えた場合のみ delete する。
      // 書き換える前（_client.register の早期失敗など）の catch では
      // 既存 working state を残す（wipe すると古いサーバー側 subscription が
      // orphan 化して掃除できなくなる — Codex 指摘）。
      if (localStateModified) {
        try {
          await PushKeyStore.delete(accountKey);
        } catch (_) {}
      }

      if (e is PushRegistrationNotSupportedException) {
        store.update(
          accountKey,
          PushRegistrationState.notSupported,
          errorMessage: e.message,
        );
      } else {
        store.update(
          accountKey,
          PushRegistrationState.failed,
          reason: subscribePhase
              ? PushRegistrationFailureReason.subscribeFailed
              : PushRegistrationFailureReason.relayFailed,
          errorMessage: _shortMessage(e),
        );
      }

      if (!_isTransient(e) && e is! PushRegistrationNotSupportedException) {
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

  /// Sentry 用の長大な message / StackTrace ではなく、UI 表示用に短縮した
  /// メッセージを作る。DioException は種別・ステータスコードに寄せ、他は
  /// runtimeType + toString を 200 文字まで。
  static String _shortMessage(Object e) {
    if (e is DioException) {
      final code = e.response?.statusCode?.toString() ?? '-';
      return 'ネットワークエラー (${e.type.name} / status=$code)';
    }
    final text = e.toString();
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }

  /// 単一アカウントのプッシュ通知登録を解除する（ログアウト経路）。
  ///
  /// **relay row は削除しない**。capsicum-relay は UNIQUE(token) で 1 デバイス
  /// = 1 row 設計のため、複数アカウントが同じ row を共有している。ここで
  /// `_client.unregister` を呼ぶと他のアカウントの endpoint を巻き添えで
  /// 破壊し、Mastodon 側の subscription が 404 で destroy される連鎖が起きる。
  /// 同一デバイスの全アカウントを同時に掃除したいときは
  /// [unregisterDevice] を別途呼び出す（例：token rotation）。
  ///
  /// SNS 側サブスクリプションの解除とローカル鍵削除は独立に try。
  /// 上流の段階が失敗しても後続の掃除を止めない。
  static Future<void> unregisterAccount(Account account) async {
    final accountKey = account.key.toStorageKey();
    PushRegistrationStatusStore.instance.remove(accountKey);

    if (account.adapter is PushSubscriptionSupport) {
      try {
        final endpoint = await PushKeyStore.getEndpoint(accountKey);
        await (account.adapter as PushSubscriptionSupport).unsubscribePush(
          endpoint: endpoint,
        );
      } catch (e, st) {
        debugPrint(
          'capsicum: push.registration: adapter unsubscribe failed: $e',
        );
        _reportUnregisterFailure(e, st, account.key.host, 'adapter');
      }
    }

    try {
      await PushKeyStore.delete(accountKey);
    } catch (e, st) {
      debugPrint('capsicum: push.registration: keystore delete failed: $e');
      _reportUnregisterFailure(e, st, account.key.host, 'keystore');
    }
  }

  /// デバイスの relay row を削除する。token rotation 時など、共有 row を
  /// 確実に掃除したい場合に呼ぶ。いずれかのアカウントの保存済み relayId
  /// を 1 つ選んで DELETE /register/:id を叩けば、row は UNIQUE なので
  /// デバイス全体の relay 登録が消える。
  static Future<void> unregisterDevice(List<Account> accounts) async {
    int? relayId;
    for (final a in accounts) {
      relayId = await PushKeyStore.getRelayId(a.key.toStorageKey());
      if (relayId != null) break;
    }
    if (relayId == null) return;
    try {
      await _client.unregister(relayId);
    } catch (e, st) {
      debugPrint('capsicum: push.registration: relay unregister failed: $e');
      _reportUnregisterFailure(e, st, '(device)', 'relay');
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
  /// トークン refresh を直列化するためのチェーン。Stream.listen は onData
  /// が async でも前回の完了を待たずに次を配信するため、複数回の rotation
  /// が短時間に重なると unregisterAccount / registerAllAccounts が交錯して
  /// key / relay state が不整合になる。各 emit をこの Future にチェイン
  /// することで厳密に one-at-a-time 化する。
  static Future<void> _tokenRefreshChain = Future<void>.value();

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
    _tokenRefreshSub = stream.listen((_) {
      // 前回の refresh を待ってから新しい refresh を走らせる（直列化）。
      // catchError で chain 自体を生かしておかないと、1 回例外が出たら
      // chain が failed future になり以降すべての emit が握り潰されて
      // プロセス終了までトークンローテーションが機能しなくなる。
      _tokenRefreshChain = _tokenRefreshChain
          .then((_) => _runTokenRefresh(getAccounts))
          .catchError((Object e, StackTrace st) {
            debugPrint('capsicum: push.registration: token refresh failed: $e');
            Sentry.captureException(
              e,
              stackTrace: st,
              withScope: (scope) {
                scope.setTag('service', 'push_registration');
                scope.setTag('phase', 'token_refresh');
              },
            );
          });
    });
  }

  static Future<void> _runTokenRefresh(
    List<Account> Function() getAccounts,
  ) async {
    debugPrint(
      'capsicum: push.registration: device token rotated, re-registering',
    );
    final accounts = getAccounts();
    if (accounts.isEmpty) return;
    // 古いリレー登録・SNS サブスクリプション・鍵を掃除してから登録し直す。
    // relay row は device-scoped（UNIQUE(token)）なので、各アカウントの
    // unregisterAccount では削除せず、最後に unregisterDevice で 1 回だけ
    // 叩く。この順序で、先に各 Mastodon/Misskey 側の subscription 解除 +
    // ローカル鍵削除を済ませ、relay row は最後にまとめて消す。
    for (final account in accounts) {
      await unregisterAccount(account);
    }
    await unregisterDevice(accounts);
    await registerAllAccounts(accounts);
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
        debugPrint(
          'capsicum: push.registration: device token not available, skipping',
        );
        return;
      }
    }

    final hasPreset = hasPresetAmong(accounts);
    // registerAccount は in-flight ガード付きで内部 try/catch も備えるため、
    // 並列化して起動時のブロック時間を短縮する。N アカウント × 2 HTTP が
    // 直列で数秒積み上がっていたのを 1 ラウンドに圧縮する。
    await Future.wait(
      accounts.map((a) => registerAccount(a, eligible: hasPreset)),
    );
  }

  /// デバイストークンの到着を最大 10 秒待つ。
  ///
  /// 呼び出し元の null チェック直後に別 microtask で `_deviceToken` が
  /// セットされた場合、素朴に `stream.first` を await するとブロードキャスト
  /// ストリームは過去 emit を再配信しないためタイムアウトまで空待ちに
  /// なる。subscribe 後に `_getDeviceToken` を再チェックすることで、Dart
  /// の単一スレッドセマンティクス上 race ウィンドウをゼロにする。
  static Future<String?> _waitForDeviceToken() async {
    final Stream<String>? stream;
    if (Platform.isIOS) {
      stream = ApnsService.onTokenChanged;
    } else if (Platform.isAndroid) {
      stream = FcmService.onTokenChanged;
    } else {
      return null;
    }

    final completer = Completer<String?>();
    final sub = stream.listen((token) {
      if (!completer.isCompleted) completer.complete(token);
    });

    // subscribe 直後の同期コンテキストでキャッシュを再確認。listen() は
    // 同期的にサブスクリプションを確立するので、ここより前に emit されて
    // いれば必ず `_deviceToken` に反映されている。
    final cached = _getDeviceToken();
    if (cached != null && !completer.isCompleted) {
      completer.complete(cached);
    }

    final timer = Timer(kDeviceTokenWait, () {
      if (!completer.isCompleted) completer.complete(null);
    });

    try {
      return await completer.future;
    } finally {
      timer.cancel();
      await sub.cancel();
    }
  }

  static String? _getDeviceToken() {
    if (Platform.isIOS) return ApnsService.deviceToken;
    if (Platform.isAndroid) return FcmService.deviceToken;
    return null;
  }

  /// OS の通知権限が明示的に拒否されているかを判定する。
  /// 現状は Android のみ判定可能（FcmService が requestPermission の結果を
  /// 保持）。iOS は APNs の権限 API をネイティブ側で公開していないため、
  /// deviceToken が null のまま判定不能で false を返す（= noDeviceToken 扱い）。
  static bool _isNotificationPermissionDenied() {
    if (Platform.isAndroid) {
      final status = FcmService.lastAuthStatus;
      return status == AuthorizationStatus.denied ||
          status == AuthorizationStatus.notDetermined;
    }
    return false;
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

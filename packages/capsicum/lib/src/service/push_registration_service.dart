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
import '../util/exception_scrub.dart';
import 'announcement_subscription_service.dart';
import 'apns_service.dart';
import 'device_install_id.dart';
import 'fcm_service.dart';
import 'push_device_type.dart';
import 'push_key_store.dart';
import 'push_registration_status.dart';
import 'push_relay_client.dart';
import 'wns_service.dart';

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

  /// 現在のプラットフォームで push backend (APNs/FCM 経由 + capsicum-relay)
  /// が本配線済みか。macOS / Linux / Windows のうち未対応のものは false にし、
  /// UI と service 層で push 機能を gate するときの単一の真実源とする (#502)。
  // iOS / Android に加え macOS も APNs 本配線済み (#468)。
  // Windows (#474) も WNS で本配線完了: Channel URI 取得 (フェーズ1) + 受信/復号
  // (フェーズ2) + 起動中 in-process 受信 (フェーズ3) が揃い、relay も
  // device_type='windows' で WNS raw 送出に対応済み (capsicum-relay d87ef2d)。
  // 未起動受信 (バックグラウンドタスク) は後続だが、起動中は #569 と併存して
  // 通知できるためゲートを立てる。Linux はネイティブ push 経路が無い (#475)。
  static bool get isPushBackendWired =>
      Platform.isIOS ||
      Platform.isAndroid ||
      Platform.isMacOS ||
      Platform.isWindows;

  static final _client = PushRelayClient();

  /// Windows: 鍵セット変更後に LocalState のバックグラウンドタスク用鍵コピー
  /// (push_keys.json) を現在の鍵セットへ再同期する (#474 フェーズ C)。ログアウト
  /// で消した鍵を bg task からも確実に除き、追加した鍵を反映する。これを怠ると、
  /// アプリ完全終了中の bg task がログアウト済みアカウントの古い鍵で push を
  /// 復号・表示し続け、平文の秘密鍵も次回起動まで残る。Windows 以外では no-op。
  /// ベストエフォート（WnsService 側で失敗は握り潰す）。
  static Future<void> _syncWnsPushKeys() async {
    if (!Platform.isWindows) return;
    await WnsService.syncPushKeys();
  }

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
      // 本配線が無いプラットフォームでは試行自体を止め、UI 上は「対象外」
      // として整合させる（#467: macOS / #471: Linux / #423: Windows）。
      // registerAllAccounts 側でも guard しているが、tokenRefresh など別経路
      // から呼ばれる場合の保険としてここでも止める。
      if (!isPushBackendWired) {
        store.update(accountKey, PushRegistrationState.skipped);
        return;
      }
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

      // relay 側で APNs/FCM/WNS の振り分けと集計を分けるため device_type を
      // プラットフォーム別に登録する。導出は [resolvePushDeviceType] に集約
      // してある（購読ゲート側と綴りを揃えるため・#919）。
      // isPushBackendWired で弾いた後なので通常 null にはならないが、両者が
      // ずれたときに未知の device_type で登録しないよう止める。
      //
      // ⚠ **ここは「対象外」ではなく内部の食い違い**なので、黙って skipped に
      // せず理由を残す (#982)。以前は debugPrint も reason も Sentry も無い完全な
      // 握りつぶしで、[isPushBackendWired] と [resolvePushDeviceType] がずれた
      // とき **手掛かりがゼロ**だった（プッシュが登録されないのに設定画面には
      // 「対象外」としか出ない）。前後の同種分岐はいずれも理由を残している。
      final deviceType = currentPushDeviceType;
      if (deviceType == null) {
        debugPrint(
          'capsicum: push.registration: no device type '
          '(isPushBackendWired と resolvePushDeviceType がずれている)',
        );
        store.update(
          accountKey,
          PushRegistrationState.failed,
          reason: PushRegistrationFailureReason.unknown,
          errorMessage: 'この環境ではプッシュ通知の送信先を判別できませんでした',
        );
        unawaited(
          Sentry.captureMessage(
            'push.registration.device_type_missing',
            level: SentryLevel.error,
            withScope: (scope) => scope.setTag('phase', 'push_registration'),
          ),
        );
        return;
      }

      // インストール単位で安定した ID (#932)。relay 側がこれをキーに upsert
      // することで、トークン更新のたびに subscription 行が増えて古い購読が
      // 孤児化する構造を止める (capsicum-relay#15)。アカウントごとではなく
      // デバイスごとの値なので、全アカウントで同じものを送る。
      final deviceId = await DeviceInstallId.get();

      // リレーサーバーに登録
      final sub = await _client.register(
        token: deviceToken,
        deviceType: deviceType,
        account: '${account.key.username}@${account.key.host}',
        server: account.key.host,
        deviceId: deviceId,
      );

      relayId = PushRelayClient.parseRelayId(sub['id']);
      final pushToken = sub['push_token'] as String?;
      if (relayId == null || pushToken == null) {
        // 応答を丸ごと出さない。`sub` には push_token（そのデバイスへ任意の
        // Web Push を投函できる capability secret）が入り、release では
        // DebugPrintIntegration が debugPrint を breadcrumb 化する。
        // main.dart の scrub は `/push/<token>` の URL 形しか消さないため、
        // `push_token: <値>` という map 表記は素通りしてしまう。
        debugPrint(
          'capsicum: push.registration: relay response missing fields: '
          'keys=${sub.keys.toList()}',
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

      // 次回起動で「再起動をまたいでトークンが変わったか」を判定するための
      // 記録 (#937)。デバイス単位の値なのでアカウントごとに同じ値を書くが、
      // 冪等なので害はない。relay row の作成が済んだ時点で書く。
      await PushKeyStore.saveDeviceToken(deviceToken);

      // ECDH 鍵の生成またはロード（既存鍵があれば再利用）
      final keys = await PushKeyStore.getOrCreate(accountKey);

      // Mastodon / Misskey に Web Push サブスクリプション登録
      final endpoint = '${PushRelayClient.relayBaseUrl}/push/$pushToken';
      // endpoint を先に永続化しておくことで、subscribePush が 4xx で失敗した
      // 場合でも unregisterAccount で Misskey 側の掃除を試みられる。
      await PushKeyStore.saveEndpoint(accountKey, endpoint);
      subscribePhase = true;
      // Misskey 本家は GHSA-7pxq-6xx9-xpgm 対策で /api/sw/register を
      // secure: true にしており、MiAuth / OAuth トークンからは叩けない。
      // モロヘイヤ導入済み Misskey サーバーでは /mulukhiya/api/sw/register
      // を proxy 経由で呼び、境界を張り直す (#355)。
      final mulukhiya = account.mulukhiya;
      if (mulukhiya != null && mulukhiya.controllerType == 'misskey') {
        // /mulukhiya/api/sw/register は mulukhiya v5.19.0 で導入された (#4254)。
        // それ以前のサーバーに送ると 404 が返るが、リトライしても改善しないため
        // notSupported に寄せて UI を「対応していません」表示に切り替える (#365)。
        if (!_mulukhiyaSupportsPushProxy(mulukhiya.version)) {
          throw PushRegistrationNotSupportedException(
            'mulukhiya ${mulukhiya.version} does not provide '
            '/mulukhiya/api/sw/register (introduced in 5.19.0)',
          );
        }
        await mulukhiya.subscribePushViaProxy(
          accessToken: account.userSecret.accessToken,
          endpoint: endpoint,
          publickey: keys.p256dh,
          auth: keys.auth,
        );
      } else {
        await (account.adapter as PushSubscriptionSupport).subscribePush(
          endpoint: endpoint,
          p256dh: keys.p256dh,
          auth: keys.auth,
        );
      }

      debugPrint(
        'capsicum: push.registration: registered ${account.key.username}@${account.key.host}',
      );
      store.update(accountKey, PushRegistrationState.registered);

      // お知らせ通知 (#477) はデフォルト ON。features.announcement_push が
      // true で明示 OFF 履歴も無いアカウントは register 完了直後に自動で
      // subscription を発行する。失敗はサービス側でログ + Sentry に流すだけで
      // 本筋は止めない (relay 障害で push 全体を失敗にする筋ではない)。
      await AnnouncementSubscriptionService.autoEnableIfDefault(account);
    } catch (e, st) {
      debugLogException(
        'capsicum: push.registration: failed for ${account.key.host}',
        e,
        st,
      );
      // NB: 登録フェーズの失敗では relay row を触らない。
      //
      // ⚠ **この判断の元の理由（UNIQUE(token) の 1 デバイス = 1 row で、
      // 全アカウントが同じ row を共有するので巻き添えになる）は、現行スキーマ
      // では成り立たない**（#950）。relay は `UNIQUE(token, account, server)` で
      // row はアカウント単位。旧スキーマは `migrate_to_subscription_scoped!` が
      // 捨てている。
      //
      // それでも触らないままにしてあるのは、**この catch が
      // `_client.register` 自体の失敗でも走り、row が作られたかどうかを
      // ここでは区別できない**ため。安全側に倒して残し、掃除は
      // `_cleanupDeviceRegistration` / ログアウト経路に任せる。
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
          scrubException(e),
          stackTrace: st,
          withScope: (scope) {
            scope.setTag('service', 'push_registration');
            scope.setTag('push.host', account.key.host);
            // scrubException で詰め替えた StateError は status / path 毎に
            // grouping が散るため、runtimeType + phase だけで集約する (#526)。
            // _captureContractViolation の fingerprint 形と整合させる。
            scope.fingerprint = [
              'push_registration',
              'register',
              e.runtimeType.toString(),
            ];
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
  /// **relay row は削除しない**。同一デバイスの全アカウントを掃除したいときは
  /// [collectRelayIds] → [unregisterDevice] を別途呼ぶ（例：token rotation）。
  ///
  /// ⚠ **かつてここに書いていた「UNIQUE(token) で 1 デバイス = 1 row だから、
  /// 消すと他アカウントを巻き添えにする」という理由は成り立たない**（#950）。
  /// 現行スキーマは `UNIQUE(token, account, server)` で **row はアカウント単位**。
  /// 旧スキーマは `migrate_to_subscription_scoped!` が捨てている。
  /// 現在この経路が row を残しているのは**惰性であって設計判断ではない**ため、
  /// ログアウトのたびに relay 側へ孤児行が 1 本残る（上流の購読は解除済みなので
  /// 配信はされない = 死んだ行が溜まるだけ）。**掃除を足すかは別途判断する。**
  ///
  /// SNS 側サブスクリプションの解除とローカル鍵削除は独立に try。
  /// 上流の段階が失敗しても後続の掃除を止めない。
  static Future<void> unregisterAccount(Account account) async {
    final accountKey = account.key.toStorageKey();
    PushRegistrationStatusStore.instance.remove(accountKey);

    if (account.adapter is PushSubscriptionSupport) {
      try {
        final endpoint = await PushKeyStore.getEndpoint(accountKey);
        final mulukhiya = account.mulukhiya;
        if (endpoint != null &&
            mulukhiya != null &&
            mulukhiya.controllerType == 'misskey') {
          // subscribe と同じ proxy 経路で解除する (#355)。mulukhiya 側の
          // SwSubscriptionContract は endpoint/publickey/auth の 3 フィールド
          // 必須。鍵が読めれば proxy 経路、読めない場合は Misskey 本家の
          // `/api/sw/unregister` を endpoint 単体で叩いて row を掃除する
          // フォールバック (#370)。v1.20 で PushKeyStore を keyset blob 化した
          // 結果、旧スキーマからアップグレードしたインストールでは
          // PushKeyStore.read が null を返す経路がある。何もしないと
          // モロヘイヤ側に Web Push 購読 row が残り、ログアウト後も relay 経由で
          // 通知が届き続ける。
          final keys = await PushKeyStore.read(accountKey);
          if (keys != null) {
            await mulukhiya.unsubscribePushViaProxy(
              accessToken: account.userSecret.accessToken,
              endpoint: endpoint,
              publickey: keys.p256dh,
              auth: keys.auth,
            );
          } else {
            await (account.adapter as PushSubscriptionSupport).unsubscribePush(
              endpoint: endpoint,
            );
          }
        } else {
          await (account.adapter as PushSubscriptionSupport).unsubscribePush(
            endpoint: endpoint,
          );
        }
      } catch (e, st) {
        debugLogException(
          'capsicum: push.registration: adapter unsubscribe failed',
          e,
        );
        _reportUnregisterFailure(e, st, account.key.host, 'adapter');
      }
    }

    try {
      await PushKeyStore.delete(accountKey);
    } catch (e, st) {
      debugLogException(
        'capsicum: push.registration: keystore delete failed',
        e,
      );
      _reportUnregisterFailure(e, st, account.key.host, 'keystore');
    }

    // お知らせ通知 (#477) の subscription 解除。relay 側 schema は
    // FK(push_token) → subscriptions に ON DELETE CASCADE が張られて
    // いるため [unregisterDevice] 経由ならば自動掃除されるが、ログアウト
    // 経路 (relay row は残す) ではここで明示 DELETE が必要。disable 内部で
    // relay エラーは握り潰すため例外は伝播しない。
    await AnnouncementSubscriptionService.disable(
      accountKey,
      host: account.key.host,
    );

    // Windows: ログアウトで消した鍵を LocalState のバックグラウンドタスク用
    // コピー (push_keys.json) からも除く (#474 フェーズ C)。これを怠ると、
    // relay の unsubscribe が遅延/失敗した窓でアプリ完全終了中に push が来ると、
    // bg task が残った古い鍵で復号してログアウト済みアカウントの通知を表示して
    // しまう。
    await _syncWnsPushKeys();
  }

  /// 各アカウントの relay 登録 id を、キーストアが消される前に読み出す (#950)。
  ///
  /// **[unregisterAccount] より先に呼ぶこと。** あちらは
  /// `PushKeyStore.delete(accountKey)` で `_Slot.relayId` を含む全スロットを
  /// 消すため、後から読んでも null しか返らない。
  static Future<List<int>> collectRelayIds(List<Account> accounts) async {
    final ids = <int>{};
    for (final a in accounts) {
      // 1 アカウント読めなかっただけで投げない。ここは起動時の掃除経路の
      // 先頭にあり、投げると呼び出し元（splash の firebaseReady チェーン）に
      // catch が無いため **registerAllAccounts ごと飛んでそのセッションが
      // プッシュ不達**になる。掃除し損ねた行は上流の失効で自然に消えるので、
      // 「掃除の取りこぼし」より「登録が立たない」方が重い。
      // reconcileDeviceToken が getDeviceToken の読み取り失敗で採っている
      // 判断と揃える。
      try {
        final id = await PushKeyStore.getRelayId(a.key.toStorageKey());
        if (id != null) ids.add(id);
      } catch (e) {
        debugLogException(
          'capsicum: push.registration: relay id read failed for '
          '${a.key.toStorageKey()}',
          e,
        );
      }
    }
    return ids.toList();
  }

  /// 渡された relay 登録 id を `DELETE /register/:id` で削除する。
  ///
  /// ⚠ **relay の row は「デバイス単位」ではない。** 現行スキーマは
  /// `UNIQUE(token, account, server)`（capsicum-relay の `lib/relay/database.rb`）
  /// で、同一端末に N アカウントを登録すれば **N 行**あり、各行が独立した
  /// `push_token` を持つ。`UNIQUE(token)` 単独は `migrate_to_subscription_scoped!`
  /// が捨てた**旧**スキーマで、この doc と実装は長らくそちらの前提のまま
  /// 「1 行消せばデバイス全体が消える」と書いていた (#950)。
  /// **1 つだけ叩くと N-1 行が孤児になる**ので、[collectRelayIds] が返した
  /// 全件を渡すこと。
  ///
  /// 個々の失敗で残りを止めない（部分的にでも消えた方がよい）。
  static Future<void> unregisterDevice(List<int> relayIds) async {
    for (final relayId in relayIds) {
      try {
        await _client.unregister(relayId);
      } catch (e, st) {
        debugLogException(
          'capsicum: push.registration: relay unregister failed',
          e,
        );
        _reportUnregisterFailure(e, st, '(device)', 'relay');
      }
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
      scrubException(e),
      stackTrace: st,
      withScope: (scope) {
        scope.setTag('service', 'push_registration');
        scope.setTag('phase', 'unregister');
        scope.setTag('stage', stage);
        scope.setTag('push.host', host);
        // status / path 毎の grouping 分散を避けるため runtimeType + stage で
        // 集約する (#526)。
        scope.fingerprint = [
          'push_registration',
          'unregister',
          stage,
          e.runtimeType.toString(),
        ];
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
    if (Platform.isIOS || Platform.isMacOS) {
      stream = ApnsService.onTokenChanged;
    } else if (Platform.isAndroid) {
      stream = FcmService.onTokenChanged;
    } else if (Platform.isWindows) {
      // WNS Channel URI 失効に伴う再取得 (#474 フェーズ2 以降で emit)。
      stream = WnsService.onTokenChanged;
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
            debugLogException(
              'capsicum: push.registration: token refresh failed',
              e,
            );
            Sentry.captureException(
              scrubException(e),
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
    await _cleanupDeviceRegistration(accounts);
    await registerAllAccounts(accounts);
  }

  /// デバイス全体のプッシュ登録を畳む。古いリレー登録・SNS サブスクリプ
  /// ション・ローカル鍵を掃除する。呼び出し側が続けて登録し直す前提。
  ///
  /// relay row は各アカウントの [unregisterAccount] では削除せず、最後に
  /// [unregisterDevice] でまとめて叩く。この順序で、先に各 Mastodon/Misskey
  /// 側の subscription 解除 + ローカル鍵削除を済ませ、relay row は最後に消す。
  ///
  /// ⚠ **relay 登録 id の読み出しは、必ず掃除ループの前に行う** (#950)。
  /// `unregisterAccount` の中の `PushKeyStore.delete(accountKey)` が
  /// `_Slot.relayId` を含む全スロットを消すため、後から
  /// `PushKeyStore.getRelayId` を舐めても null しか得られず、
  /// **`DELETE /register/:id` が一度も発行されない**（v1.53 以前から同じ順序
  /// だったが、#937 の `reconcileDeviceToken` が「毎起動でトークン変化を検出
  /// したら掃除」という高頻度トリガをこの経路に繋いだので効き方が変わった）。
  ///
  /// お知らせ通知 (#477) は opt-out モデルに移行したので、明示 OFF 履歴の
  /// 無いアカウントは [_registerAccountImpl] 末尾の autoEnableIfDefault で
  /// 自動的に復活する。手動 restore は不要。
  static Future<void> _cleanupDeviceRegistration(List<Account> accounts) async {
    final relayIds = await collectRelayIds(accounts);
    for (final account in accounts) {
      await unregisterAccount(account);
    }
    await unregisterDevice(relayIds);
    // 掃除した以上、記録済みトークンは「登録に使われている値」ではなくなる。
    // 残すと次回起動の突き合わせ ([reconcileDeviceToken]) が誤検知する。
    await PushKeyStore.deleteDeviceToken();
  }

  /// 前回の登録に使ったデバイストークンと現在値を突き合わせ、変わっていれば
  /// 上流の古いサブスクリプションを掃除する (#937)。**登録し直しは行わない**
  /// ので、呼び出し側は続けて [registerAllAccounts] すること。
  ///
  /// [startTokenRefreshListener] が観測できるのは **プロセス内の** ローテー
  /// ションだけである。起動時は `WnsService._channelUri` などの in-memory 値が
  /// null から始まるため、前回と違うトークンを受け取っても「変化」として emit
  /// されず、掃除の走らないまま新しい endpoint で登録される。
  ///
  /// endpoint は `${relayBaseUrl}/push/${push_token}` で、`push_token` は relay
  /// の行（`UNIQUE(token, account, server)`・`token` はデバイストークン）が新規
  /// 作成されたときだけ発行される。よってトークンが変わると endpoint も変わる。
  /// **Misskey の `sw/register` は `(userId, endpoint, auth, publickey)` で引いて
  /// 無ければ INSERT する**（pooza フォークの `findOneBy`・#960 で実装確認。auth /
  /// publickey まで含めて一致しないと別行になる）。加えて
  /// `_cleanupDeviceRegistration` は keyset ごと捨てて再生成するので、**endpoint
  /// 据え置きでも必ず新しい `sw_subscription` 行になる**。古い購読は孤児として
  /// 残る（Mastodon は create 冒頭で既存を destroy するので残らない）。孤児は
  /// 失効まで生き続け、同じ通知が複数回届く。
  static Future<void> reconcileDeviceToken(List<Account> accounts) async {
    if (!isPushBackendWired || accounts.isEmpty) return;
    final String? current = _getDeviceToken() ?? await _waitForDeviceToken();
    if (current == null) {
      _reportReconcile('no_token', accounts);
      return;
    }

    final String? previous;
    try {
      previous = await PushKeyStore.getDeviceToken();
    } catch (e) {
      // 読めなければ判定できない。掃除せず通常の登録へ進む（誤って掃除して
      // push を止めるより、重複が残る方が軽い）。
      debugLogException(
        'capsicum: push.registration: device token read failed',
        e,
      );
      return;
    }
    // 未保存（本機能の導入前・初回起動）は変化と判定できない。既存の孤児は
    // 古いトークンの失効に伴い relay の 410 経路で自然に掃除される。
    if (previous == null || previous == current) {
      _reportReconcile(previous == null ? 'first_run' : 'unchanged', accounts);
      return;
    }

    debugPrint(
      'capsicum: push.registration: device token changed across restarts, '
      'cleaning up stale subscriptions',
    );
    _reportReconcile('changed', accounts);
    // どのプラットフォームでどれだけ起きるかが分からないと #932 の効き方も
    // 評価できないので計測する。トークンそのものは載せない。CAPSICUM-48 の
    // トリアージ継続のため、母数 (`push.reconcile`) とは別イベントで残す。
    Sentry.captureMessage(
      'push.token_changed_across_restart',
      level: SentryLevel.info,
      withScope: (scope) {
        scope.setTag('push.platform', Platform.operatingSystem);
        scope.setTag('push.accounts', accounts.length.toString());
        scope.fingerprint = ['push.token_changed_across_restart'];
      },
    );
    await _cleanupDeviceRegistration(accounts);
  }

  /// 再起動をまたいだトークン照合の結果を計測する (#960)。
  ///
  /// [reconcileDeviceToken] は毎起動で走るので、これが
  /// `push.token_changed_across_restart`（= `outcome:changed`）の**分母**になる。
  /// この 1 イベントに `outcome` タグ（first_run / unchanged / changed /
  /// no_token）を載せておけば、プラットフォーム別に「何回の起動のうち何回
  /// トークンが変わったか」を Sentry のタグ集計だけで出せる。プッシュ非対応
  /// ビルドとアカウント 0 件の起動は、そもそも変化が起きえないので数えない
  /// （分母から外す）。トークンを取れなかった起動は `no_token` として数え、
  /// 「取れていない」こと自体も見えるようにする。従来は成功側の計装がアプリ内 UI
  /// ([PushRegistrationStatusStore]) と debugPrint だけで、近い分母の
  /// `app.startup.restore` は [startupTracesSampleRate] = 0.2 のため素で割ると
  /// 実勢の 5 倍にズレていた。ここは sampling せず 1 起動 1 件で出す。
  static void _reportReconcile(String outcome, List<Account> accounts) {
    Sentry.captureMessage(
      'push.reconcile',
      level: SentryLevel.info,
      withScope: (scope) {
        scope.setTag('push.platform', Platform.operatingSystem);
        scope.setTag('push.reconcile_outcome', outcome);
        scope.setTag('push.accounts', accounts.length.toString());
        scope.fingerprint = ['push.reconcile'];
      },
    );
  }

  /// 全アカウントのプッシュ通知登録を行う（アプリ起動時に呼ぶ）。
  ///
  /// プリセットサーバーのアカウントが1つでもあれば、全アカウントを登録対象とする。
  /// デバイストークンが未取得の場合は到着を待ってから登録する。
  static Future<void> registerAllAccounts(List<Account> accounts) async {
    if (accounts.isEmpty) return;

    // 本配線が無いプラットフォームでは _waitForDeviceToken (最大 10 秒) を
    // 走らせず、各アカウントを「対象外」状態に揃えて即時 return する
    // （#467: macOS / #471: Linux / #423: Windows）。
    if (!isPushBackendWired) {
      final store = PushRegistrationStatusStore.instance;
      for (final account in accounts) {
        store.update(account.key.toStorageKey(), PushRegistrationState.skipped);
      }
      return;
    }

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
    //
    // ただし Windows は flutter_secure_storage が単一ファイル
    // (flutter_secure_storage.dat) を read-modify-write するため、複数アカウント
    // を並列登録すると PushKeyStore の write 同士が同ファイルを同時に開いて
    // PathAccessException（共有違反）になる (#474)。iOS/Android/macOS は
    // Keychain/Keystore が並行安全なので並列のまま。Windows のみ直列化する。
    if (Platform.isWindows) {
      for (final a in accounts) {
        await registerAccount(a, eligible: hasPreset);
      }
    } else {
      await Future.wait(
        accounts.map((a) => registerAccount(a, eligible: hasPreset)),
      );
    }

    // Windows: 登録で生成・更新した鍵を LocalState のバックグラウンドタスク用
    // コピー (push_keys.json) へ反映する (#474 フェーズ C)。起動時のネイティブ
    // 初回同期は Dart の鍵生成より先に走ることがあり取りこぼすため、登録完了後に
    // 再同期して確実に最新化する。
    await _syncWnsPushKeys();
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
    if (Platform.isIOS || Platform.isMacOS) {
      stream = ApnsService.onTokenChanged;
    } else if (Platform.isAndroid) {
      stream = FcmService.onTokenChanged;
    } else if (Platform.isWindows) {
      stream = WnsService.onTokenChanged;
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
    // macOS は iOS と同じ APNs MethodChannel (ApnsService) からトークンを得る。
    if (Platform.isIOS || Platform.isMacOS) return ApnsService.deviceToken;
    if (Platform.isAndroid) return FcmService.deviceToken;
    // Windows は WNS Channel URI を device token とみなす (#474)。
    if (Platform.isWindows) return WnsService.deviceToken;
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

  /// mulukhiya proxy が `/sw/register` をホスト可能か（v5.19.0 以降）を判定。
  /// `version` は package.json の version 文字列で `MAJOR.MINOR.PATCH` 想定。
  /// パース失敗時は `false`（未サポート扱い）にフォールバックする。
  static bool _mulukhiyaSupportsPushProxy(String version) {
    final parts = version.split('.');
    if (parts.length < 2) return false;
    final major = int.tryParse(parts[0]);
    final minor = int.tryParse(parts[1]);
    if (major == null || minor == null) return false;
    if (major > 5) return true;
    if (major < 5) return false;
    return minor >= 19;
  }

  /// ネットワーク瞬断など通常の運用で発生しうる一過性エラーかどうか。
  /// 一過性は Sentry に送らず、バグや契約違反のみに集中する。
  static bool _isTransient(Object e) {
    if (e is SocketException) return true;
    if (e is TimeoutException) return true;
    if (FcmService.isTransient(e)) return true;
    if (e is DioException) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionError) {
        return true;
      }
      // リレー / Mastodon / Misskey の一時障害・過負荷で 5xx や 429 が返る
      // ケースは transient として扱う。Sentry に送っても原因追跡に寄与せず
      // ノイズになるだけで、次回起動や再試行で解消する。
      if (e.type == DioExceptionType.badResponse) {
        final status = e.response?.statusCode ?? 0;
        if (status == 429 || (status >= 500 && status < 600)) return true;
      }
    }
    return false;
  }

  /// リレー応答がスキーマを満たさないなど、サーバー契約違反を Sentry に記録する。
  static void _captureContractViolation(String message, String host) {
    Sentry.captureException(
      StateError(message),
      withScope: (scope) {
        scope.setTag('service', 'push_registration');
        scope.setTag('type', 'contract_violation');
        scope.setTag('push.host', host);
      },
    );
  }
}

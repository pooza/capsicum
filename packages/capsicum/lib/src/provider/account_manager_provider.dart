import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../constants.dart';
import '../model/account.dart';
import '../model/account_key.dart';
import '../model/offline_account.dart';
import '../service/account_storage.dart';
import '../service/background_notification_service.dart';
import '../service/notification_label_cache.dart';
import '../service/push_registration_service.dart';
import '../service/server_metadata_cache.dart';
import '../service/timeline_cache.dart';
import '../service/wns_service.dart';
import '../util/login_error.dart';
import '../util/sentry_tag_hash.dart';
import '../util/exception_scrub.dart';

/// State: list of accounts + currently selected account.
class AccountManagerState {
  final List<Account> accounts;
  final Account? current;

  /// 到達不能でオンライン復元できていないログイン済みアカウント (#792)。
  /// 一覧から消さず切替 UI に greyed 表示し、背景リトライで [accounts] へ昇格
  /// させる。`accounts` が空でもこれが非空なら「ログアウト」ではない。
  final List<OfflineAccount> offlineAccounts;

  const AccountManagerState({
    this.accounts = const [],
    this.current,
    this.offlineAccounts = const [],
  });

  /// 「ログイン済みとみなす」かどうかの単一の判定 (#917)。
  ///
  /// [current] が null でも [offlineAccounts] が残っていれば **ログアウトでは
  /// ない**。到達不能なだけで secret は保持しており、復帰すれば昇格する (#792)。
  ///
  /// **この判定を各所に書き散らさないこと。**#792 は splash 側にだけ入れて
  /// router の redirect に入れ忘れており、splash が `/home` へ送った直後に
  /// redirect が `/server` へ引き戻していた。オフライン起動でログイン画面が
  /// 出る (#917) の原因はその二重管理だった。
  bool get hasSession => current != null || offlineAccounts.isNotEmpty;

  /// 未指定と「明示 null」を区別するための番兵。`current` は logout で null に
  /// 落とす経路があるため、`current ?? this.current` だと null 化を表現できない。
  static const _unset = Object();

  AccountManagerState copyWith({
    List<Account>? accounts,
    Object? current = _unset,
    List<OfflineAccount>? offlineAccounts,
  }) => AccountManagerState(
    accounts: accounts ?? this.accounts,
    current: identical(current, _unset) ? this.current : current as Account?,
    offlineAccounts: offlineAccounts ?? this.offlineAccounts,
  );
}

/// オフライン保持アカウントの背景再試行、立ち上がりの間隔 (#792)。
/// サーバー再構築直後の復帰を素早く拾うために短く刻む。
const kOfflineRetryRampUp = [
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 15),
  Duration(seconds: 30),
];

/// 立ち上がりを使い切った後の定常間隔 (#938)。
const kOfflineRetrySteadyInterval = Duration(seconds: 60);

/// [attempt] 回目（0 始まり）の背景再試行までの待ち時間 (#938)。
///
/// **どの [attempt] に対しても値を返す＝打ち切らないのが本質。** 以前は
/// [kOfflineRetryRampUp] の 4 回・計 52 秒でループを終了し、以降の自動トリガが
/// 一切無かったため「接続が戻っても、画面を開いたまま待っていてもタイムラインへ
/// 復帰しない」状態になっていた。
///
/// #792 が想定していたのはサーバー再構築中の一時的な不通で、その文脈なら 52 秒は
/// 妥当だった。しかし #917 で **この画面は端末側がオフラインのときにも出る**ことが
/// 分かった。機内モードや回線断から復帰するのはたいてい 52 秒より後なので、
/// **この画面が最も出やすい状況でこそ自動復帰が効かない**という形だった。
///
/// 常駐コストはオフライン保持中のアカウント 1 つにつき 60 秒に 1 回の probe。
/// オンラインへ戻れば対象が空になりループ自体が終わる。モバイルはバックグラウンド
/// で実行が止まるので、そこは
/// [AccountManagerNotifier.refreshOfflineRestoresOnResume] が復帰時に補う。
Duration offlineRetryDelay(int attempt) => attempt < kOfflineRetryRampUp.length
    ? kOfflineRetryRampUp[attempt]
    : kOfflineRetrySteadyInterval;

class AccountManagerNotifier extends Notifier<AccountManagerState> {
  @override
  AccountManagerState build() {
    ref.onDispose(() => _disposed = true);
    return const AccountManagerState();
  }

  /// provider が破棄されたか。背景再試行ループ ([_retryOfflineRestores]) は
  /// 打ち切りを持たないので、これを見て抜ける。
  bool _disposed = false;

  /// 背景再試行ループが走っているか。ループが無限になった (#938) 以上、
  /// 二重起動すると probe が恒久的に 2 倍走る。
  bool _offlineRetryLoopRunning = false;

  /// host ごとのモロヘイヤ自動再検出の最終実行時刻。フォアグラウンド復帰 / ドロワー
  /// 表示のたびに `/about` を叩かないよう TTL で間引く (#775)。
  final _mulukhiyaAutoRefreshedAt = <String, DateTime>{};
  static const _mulukhiyaAutoRefreshTtl = kServerMetadataFreshnessTtl;

  Future<void> addAccount(Account account) async {
    final storage = ref.read(accountStorageProvider);
    final secrets = <String, String>{
      'access_token': account.userSecret.accessToken,
      if (account.userSecret.refreshToken != null)
        'refresh_token': account.userSecret.refreshToken!,
      if (account.clientSecret != null) ...{
        'client_id': account.clientSecret!.clientId,
        'client_secret': account.clientSecret!.clientSecret,
      },
    };
    await storage.saveAccount(account.key.toStorageKey(), secrets);

    // Detect timeline availability (non-blocking).
    final adapter = account.adapter;
    if (adapter is MastodonAdapter) {
      try {
        await adapter.detectTimelineAvailability();
      } catch (e) {
        debugPrint(
          'capsicum: addAccount: detectTimelineAvailability failed for '
          '${account.key.toStorageKey()}: $e',
        );
      }
    }

    // Detect mulukhiya on the server (non-blocking — failure is fine).
    final mulukhiya = await _detectMulukhiya(
      account.key.host,
      token: account.userSecret.accessToken,
    );
    if (mulukhiya != null) {
      if (account.adapter is MastodonAdapter) {
        (account.adapter as MastodonAdapter).applyAdminRoleIds(
          mulukhiya.adminRoleIds,
        );
      } else if (account.adapter is MisskeyAdapter) {
        (account.adapter as MisskeyAdapter).applyAdminRoleIds(
          mulukhiya.adminRoleIds,
        );
      }
    }
    final enriched = mulukhiya != null
        ? Account(
            key: account.key,
            adapter: account.adapter,
            user: account.user,
            userSecret: account.userSecret,
            clientSecret: account.clientSecret,
            mulukhiya: mulukhiya,
            softwareVersion: account.softwareVersion,
          )
        : account;

    final newAccounts = [enriched, ...state.accounts];
    // 手動ログインで復帰したサーバーがオフライン保持中なら、その entry を落と
    // して二重表示を防ぐ (#792)。
    final offline = state.offlineAccounts
        .where((o) => o.key != enriched.key)
        .toList();
    state = state.copyWith(
      accounts: newAccounts,
      current: enriched,
      offlineAccounts: offline,
    );

    // Prefetch server metadata for badge display (non-blocking). Misskey
    // フォークの偽 Mastodon 互換版で name/icon が化けないよう型ヒントを渡す (#827)。
    ServerMetadataCache.instance.fetch(
      account.key.host,
      preferMisskey: account.adapter is ReactionSupport,
    );

    // 通知ラベル（ブースト/投稿）を FCM バックグラウンド isolate 用に焼く。
    // registerAccount より先に完了させる: 登録直後に届く最初のプッシュが
    // ラベル未保存のまま既定値（ブースト/投稿）に化けないように。
    await _persistNotificationLabels(enriched);
    await _syncWindowsPushLabels();

    // プッシュ通知登録（ベストエフォート）。
    // 既存アカウントにプリセットサーバーがあれば、新規アカウントも登録対象。
    final hasPreset = PushRegistrationService.hasPresetAmong(newAccounts);
    PushRegistrationService.registerAccount(enriched, eligible: hasPreset);
  }

  void switchAccount(Account account) {
    final reordered = [
      account,
      ...state.accounts.where((a) => a.key != account.key),
    ];
    state = state.copyWith(accounts: reordered, current: account);

    // Persist MRU order in background (failure is non-fatal).
    final storage = ref.read(accountStorageProvider);
    storage.touchAccount(account.key.toStorageKey()).catchError((_) {});

    // Clear unread notification count for the account we're switching to.
    BackgroundNotificationService.clearUnreadCount(account.key.toStorageKey());

    // Prefetch server metadata for badge display (non-blocking). Misskey
    // フォークの偽 Mastodon 互換版で name/icon が化けないよう型ヒントを渡す (#827)。
    ServerMetadataCache.instance.fetch(
      account.key.host,
      preferMisskey: account.adapter is ReactionSupport,
    );
  }

  void updateCurrentUser(User user) {
    final current = state.current;
    if (current == null) return;
    final updated = current.copyWithUser(user);
    final accounts = state.accounts
        .map((a) => a.key == updated.key ? updated : a)
        .toList();
    state = state.copyWith(accounts: accounts, current: updated);
  }

  Future<void> logout(Account account) async {
    // プッシュ通知登録解除（ベストエフォート）。
    PushRegistrationService.unregisterAccount(account);
    await NotificationLabelCache.remove(_notificationLabelKey(account));

    final storage = ref.read(accountStorageProvider);
    await storage.removeAccount(account.key.toStorageKey());
    // 起動時に先出しする TL のキャッシュ (#890) は、ログアウトしたアカウントの
    // 投稿を残さないよう捨てる。contextKey が一致しなければ使われない作りだが、
    // 端末上に残す理由も無い。
    await TimelineCache.clear();

    final remaining = state.accounts
        .where((a) => a.key != account.key)
        .toList();

    final next = (state.current?.key == account.key)
        ? (remaining.isNotEmpty ? remaining.first : null)
        : state.current;

    state = state.copyWith(
      accounts: remaining,
      current: next,
      offlineAccounts: state.offlineAccounts
          .where((o) => o.key != account.key)
          .toList(),
    );
    // 残ったアカウントのラベルで push_labels.json を更新（削除分を落とす、#770）。
    await _syncWindowsPushLabels();
  }

  /// Re-detect mulukhiya on the current account's server and update state.
  Future<bool> redetectMulukhiya() async {
    final before = state.current;
    if (before == null) return false;

    final mulukhiya = await _detectMulukhiya(
      before.key.host,
      token: before.userSecret.accessToken,
    );
    if (mulukhiya == null) return false;

    // await 中にアカウント切替 / ログアウトが起きている可能性がある。自動再検出
    // (#775) はドロワー表示・フォアグラウンド復帰から発火し、ドロワーはアカウント
    // 切替 UI そのものなので、`/about` 往復中に current が変わりうる。対象アカウント
    // が今も存在する場合のみ反映する（[refreshCurrentServerVersion] と同じガード）。
    // これが無いと、切替後に current が旧アカウントへ巻き戻る／ログアウト済みの
    // アカウントを current が指すゾンビ状態になる。
    final idx = state.accounts.indexWhere((a) => a.key == before.key);
    if (idx < 0) return false;
    final target = state.accounts[idx];

    if (target.adapter is MastodonAdapter) {
      (target.adapter as MastodonAdapter).applyAdminRoleIds(
        mulukhiya.adminRoleIds,
      );
    } else if (target.adapter is MisskeyAdapter) {
      (target.adapter as MisskeyAdapter).applyAdminRoleIds(
        mulukhiya.adminRoleIds,
      );
    }
    final updated = target.copyWithMulukhiya(mulukhiya);
    final accounts = [...state.accounts];
    accounts[idx] = updated;
    state = state.copyWith(
      accounts: accounts,
      current: state.current?.key == updated.key ? updated : state.current,
    );
    // 手動再検出も自動再検出 (#775) の TTL を消費させ、直後のフォアグラウンド
    // 復帰で二重に `/about` を叩かないようにする。
    _mulukhiyaAutoRefreshedAt[before.key.host] = DateTime.now();
    await _persistNotificationLabels(updated);
    await _syncWindowsPushLabels();
    return true;
  }

  /// 現在アカウントのサーバーソフトウェアバージョンを [ServerMetadataCache]
  /// （TTL 付き）経由で取り直し、変化していれば state に反映する (#774)。
  /// `softwareVersion` はセッション復元時に NodeInfo を一度だけ probe して保持され、
  /// サーバーをアップデートしても再起動まで古いままだった。フォアグラウンド復帰
  /// （[_HomeScreenState]）とドロワー / サーバー情報画面表示のたびに呼ぶ。TTL 内なら
  /// キャッシュ即返しでネットワークは走らない。[force] で TTL を無視して再取得する
  /// （サーバー情報画面を開いた直後の確実な最新化）。
  ///
  /// version が取得できなかった（null）ときは既存値を維持する。version は
  /// Collections のゲート (#810) にも使うため、一過性の取得失敗で good な値を
  /// null に落とさない。
  Future<void> refreshCurrentServerVersion({bool force = false}) async {
    final before = state.current;
    if (before == null) return;
    final host = before.key.host;
    // Misskey フォーク（Sharkey/Firefish 等）は /api/v2/instance に偽 Mastodon
    // 互換版を返すため、Misskey 系アダプタでは /api/meta を優先して真のフォーク版
    // を取り直す (#827)。これが無いと初回リフレッシュで表示版が 4.x に化ける。
    final metadata = await ServerMetadataCache.instance.fetch(
      host,
      forceRefresh: force,
      preferMisskey: before.adapter is ReactionSupport,
    );
    final version = metadata?.softwareVersion;
    if (version == null) return;

    // await 中にアカウント切替 / ログアウトが起きている可能性があるため、対象
    // アカウントが今も存在し version が実際に変化した場合のみ反映する。
    final idx = state.accounts.indexWhere((a) => a.key == before.key);
    if (idx < 0) return;
    final target = state.accounts[idx];
    if (target.softwareVersion == version) return;

    final updated = target.copyWithSoftwareVersion(version);
    final accounts = [...state.accounts];
    accounts[idx] = updated;
    state = state.copyWith(
      accounts: accounts,
      current: state.current?.key == updated.key ? updated : state.current,
    );
  }

  /// 現在アカウントのモロヘイヤ機能フラグ（version / `config.features.*`）を TTL で
  /// 自動再検出する (#775)。#774 の softwareVersion と同じく起動時一度きり probe で、
  /// サーバー側でモロヘイヤをアップデート / 機能を有効化しても再起動または手動
  /// 「再検出」まで反映されず、「使えるはずの機能（メディアカタログ / 劇中ワード辞書 /
  /// nowplaying 等）が使えないまま」になっていた。[refreshCurrentServerVersion] と
  /// 同じトリガー（フォアグラウンド復帰・ドロワー表示）から呼ぶ。
  ///
  /// [redetectMulukhiya] は `/about` を叩き push ラベル永続化まで伴うため、host
  /// ごとの TTL で間引く。手動再検出ボタンは即時性が要るので TTL を経由しない。
  Future<void> refreshCurrentMulukhiya() async {
    final current = state.current;
    if (current == null) return;
    final host = current.key.host;
    final last = _mulukhiyaAutoRefreshedAt[host];
    if (last != null &&
        DateTime.now().difference(last) < _mulukhiyaAutoRefreshTtl) {
      return;
    }
    // 再入・多重呼び出しの抑止も兼ねて、実行前に時刻を記録する。TTL 内の失敗も
    // 次の TTL 満了まで待つ（非モロヘイヤ鯖で毎復帰ごとに /about を叩かない）。
    _mulukhiyaAutoRefreshedAt[host] = DateTime.now();
    await redetectMulukhiya();
  }

  /// フォアグラウンド復帰・ドロワー表示から呼ぶサーバーメタデータ鮮度更新の
  /// まとめ口 (#828)。バージョン表示 (#774) とモロヘイヤ機能フラグ (#775) は
  /// 常に対で取り直すため、呼び出し側の二重記述を避けてここに集約する。
  /// いずれも TTL 内は no-op。
  Future<void> refreshCurrentServerMetadata() async {
    await Future.wait([
      refreshCurrentServerVersion(),
      refreshCurrentMulukhiya(),
    ]);
  }

  /// [Account] を `username@host` 形式に直す。capsicum-relay が push payload
  /// に載せる `account` 文字列・[NotificationLabelCache] のキー・通知ルート
  /// 解決用と全経路で同一フォーマットを使う。
  static String _notificationLabelKey(Account account) =>
      '${account.key.username}@${account.key.host}';

  /// [Account] から「ブースト/リノート/リキュア！」「投稿」ラベルを解決し、
  /// FCM バックグラウンド isolate / iOS NSE からも参照できるよう永続化する。
  /// 解決ロジックは [main._resolveReblogLabelForAccount] と揃っている必要が
  /// ある（Mastodon=ブースト、Misskey=リノート、mulukhiya があれば上書き）。
  ///
  /// 呼び出し元は push 登録前に await すること: 登録直後の最初のプッシュが
  /// ラベル未保存のまま既定値に化けるレースを避けるため。
  Future<void> _persistNotificationLabels(Account account) async {
    final labels = _resolveNotificationLabels(account);
    await NotificationLabelCache.save(
      _notificationLabelKey(account),
      reblogLabel: labels.reblog,
      postLabel: labels.post,
    );
  }

  /// [Account] から reblog（ブースト/リノート/リキュア！等）と post（投稿）の
  /// 表示ラベルを解決する。[main._resolveReblogLabelForAccount] / Windows native
  /// の既定（notification_type_label.cpp）と文言を揃えること。
  static ({String reblog, String post}) _resolveNotificationLabels(
    Account account,
  ) {
    final mulukhiya = account.mulukhiya;
    final reblog =
        mulukhiya?.reblogLabel ??
        (account.adapter is ReactionSupport ? 'リノート' : 'ブースト');
    final post = mulukhiya?.postLabel ?? '投稿';
    return (reblog: reblog, post: post);
  }

  /// Windows: 完全終了中の bg task / 起動中の in-process 受信が読む
  /// push_labels.json を、現在ログイン中の全アカウントのラベルで更新する (#770)。
  /// native はプロセスを跨いで Dart の shared_preferences（[NotificationLabelCache]）
  /// を読めないため、push 鍵同期（[WnsService.syncPushKeys]）と同じ LocalState
  /// 契約でラベルを渡す。ラベル変更（ログイン / ログアウト / mulukhiya 再検出 /
  /// 復元）のたびに呼ぶ。Windows 以外は no-op。鍵と違い欠落しても native は既定
  /// ラベルにフォールバックするためベストエフォート。
  Future<void> _syncWindowsPushLabels() async {
    if (!Platform.isWindows) return;
    final map = <String, String>{};
    for (final account in state.accounts) {
      final labels = _resolveNotificationLabels(account);
      map[_notificationLabelKey(account)] = jsonEncode({
        'reblog': labels.reblog,
        'post': labels.post,
      });
    }
    await WnsService.syncPushLabels(jsonEncode(map));
  }

  /// Detect software version via NodeInfo on the given host.
  Future<String?> _detectSoftwareVersion(String host) async {
    try {
      final dio = Dio(BaseOptions(connectTimeout: kNetworkConnectTimeout));
      final probe = await probeInstance(dio, host);
      return probe?.softwareVersion;
    } catch (e) {
      debugLogException(
        'capsicum: software version detection error on $host',
        e,
      );
      return null;
    }
  }

  /// Detect mulukhiya on the given host.
  ///
  /// [token] を渡すと /about を bearer 認証付きで叩き、`annict_linked` 等の
  /// per-user フラグが当該アカウントで評価される (#611)。無認証だと
  /// サーバーの default_token 基準になり連携状態を誤判定する。
  Future<MulukhiyaService?> _detectMulukhiya(
    String host, {
    String? token,
  }) async {
    try {
      // ⚠ この Dio は detect 用の使い捨てではなく、**成功したら
      // MulukhiyaService がそのまま抱えて以降の全 API で使い続ける**。
      // #900 で既定タイムアウトを入れたのは Mastodon / Misskey の
      // アダプター用 Dio だけで、こちらは connectTimeout しか無く
      // receive / send が無制限のまま残っていた (#951)。
      //
      // 無制限だと、モロヘイヤ導入サーバーが TCP は受けるのに応答を返さない
      // 状態になったとき `subscribePushViaProxy` が永久に返らず、
      // `registerAllAccounts` の `Future.wait` ごと固まる。splash はその
      // await の直後で `startTokenRefreshListener` を張るので、**そのセッション
      // 中ずっと token rotation を拾えなくなる**。
      //
      // 値はアダプターと揃える。5 秒側（`kNetworkReceive*`）を当てないのは、
      // 番組表など重い API を正常系ごと切ってしまうため。receiveTimeout が
      // 「ヘッダー到達までの絶対上限」にも効く点は network_timeouts.dart の
      // doc が正本。detect() 自身は per-request Options で 5 秒を当てており、
      // per-request が BaseOptions を上書きするのでその見切りの速さは保たれる。
      final dio = Dio(
        BaseOptions(
          connectTimeout: kNetworkConnectTimeout,
          receiveTimeout: kAdapterReceiveTimeout,
          sendTimeout: kAdapterSendTimeout,
        ),
      );
      final mulukhiya = await MulukhiyaService.detect(dio, host, token: token);
      if (mulukhiya != null) {
        debugPrint(
          'capsicum: mulukhiya detected on $host '
          '(${mulukhiya.controllerType} v${mulukhiya.version})',
        );
      } else {
        debugPrint('capsicum: mulukhiya not found on $host');
      }
      return mulukhiya;
    } catch (e) {
      debugLogException('capsicum: mulukhiya detection error on $host', e);
      return null;
    }
  }

  /// Restore sessions from secure storage on app start.
  ///
  /// Returns the number of accounts that could not be restored due to
  /// decryption failure or other errors (e.g. encryption key regenerated
  /// after OS update / device reset).
  Future<int> restoreSessions() async {
    final storage = ref.read(accountStorageProvider);
    final keys = await storage.getAccountKeys();
    var skippedCount = 0;
    // 一時的な到達不能で落ちたアカウント（secret は有効）。オフライン保持し
    // ながらバックグラウンドで再試行する (#730 / #792)。ネットワーク不通に
    // 加えサーバー 5xx（再構築中など）も含む。
    final retriableFailures =
        <({String keyStr, Map<String, String> secrets})>[];

    // secret が一過性で読めなかった（Keychain ロック等）アカウント (#959)。
    // 索引はあるので「N 件あるのに読めなかった」ことは分かる。ログアウト扱い
    // （skip）にすると #917 で直したのと同じ「ログアウトされた」画面（/server へ
    // 引き戻し）になるため、オフライン保持して hasSession を保つ。
    final transientOffline = <AccountKey>[];

    // secret を読み出せたアカウントだけを probe 対象に集める。順序は
    // getAccountKeys（＝MRU）を保持し、後段の一括反映でこの並びを使う。
    final entries = <({String keyStr, Map<String, String> secrets})>[];
    for (final keyStr in keys) {
      Map<String, String>? secrets;
      try {
        secrets = await storage.getSecrets(keyStr);
      } on TransientSecretUnavailableException {
        // secret は無傷だが今は読めない (#959)。secret 未取得なので background
        // ループ（cached secret 前提）には載せられない。オフライン保持だけして、
        // resume / 手動再試行 (_retryOfflineRestoresNow) が getSecrets を読み直して
        // 復帰させる。AccountKey が parse できない破損 key は表現を作れず skip。
        final key = _tryParseStorageKey(keyStr);
        if (key != null) {
          transientOffline.add(key);
        } else {
          skippedCount++;
        }
        continue;
      }
      if (secrets == null) {
        // secret が例外なく単に存在しない (`getSecrets` の raw==null) 経路。
        // インデックス (#337 で分離) は生存しているのに secure storage 側の
        // secret だけが消えた典型シグナル (再インストール / データ削除 / 端末
        // 復元・機種変 / OS 由来の Keystore リセット)。挙動自体は #277 / #337 の
        // 設計通り (再ログインを促す) だが、例外を投げないため従来は Sentry に
        // 一切出ず、規模・頻度・プラットフォーム傾向が観測できなかった (#704)。
        // 例外経路 (`_reportRestoreOnce`) と区別できる軽量メッセージを 1 度だけ送る。
        _reportNullSecretSkipOnce(keyStr);
        skippedCount++;
        continue;
      }
      entries.add((keyStr: keyStr, secrets: secrets));
    }

    // 全アカウントを同時に probe する (#716 段階2)。直列だと N アカウントで
    // probe 時間が累積していたのを、最長 1 アカウントぶんへ畳む。各 probe は
    // 例外を内部で分類して結果レコードに畳むため Future.wait は throw しない。
    final results = await Future.wait(
      entries.map((e) => _probeForRestore(e.keyStr, e.secrets)),
    );

    // 完了順ではなく entries（＝MRU 順）の並びで結果を確定し、並び・current の
    // ブレを防ぐ。
    final restored = <Account>[];
    final offline = <OfflineAccount>[];
    for (var i = 0; i < entries.length; i++) {
      final r = results[i];
      if (r.account != null) {
        restored.add(r.account!);
      } else if (r.outcome == RestoreOutcome.retriable) {
        // 一時的な到達不能。消さずオフライン保持し、背景リトライへ回す (#792)。
        // AccountKey が parse できない破損 key はオフライン表現を作れないので
        // 従来どおり skip する。
        final key = _tryParseStorageKey(entries[i].keyStr);
        if (key != null) {
          offline.add(OfflineAccount(key: key));
          retriableFailures.add(entries[i]);
        } else {
          skippedCount++;
        }
      } else {
        // authRevoked（再ログイン）/ giveUp（secret 系・4xx・不明）は従来どおり
        // skip して観測する。
        skippedCount++;
      }
    }

    // secret が一過性で読めなかったアカウントもオフライン保持へ加える (#959)。
    // これで hasSession が true になり /server へ引き戻されなくなる。
    offline.addAll(transientOffline.map((key) => OfflineAccount(key: key)));

    if (restored.isNotEmpty || offline.isNotEmpty) {
      // MRU 順を保ったまま一括反映する。current は先頭（＝MRU 先頭）。splash 中は
      // 通常 state は空だが、万一別経路が先に追加したアカウントがあれば温存する。
      final existing = state.accounts
          .where((a) => restored.every((r) => r.key != a.key))
          .toList();
      final onlineAccounts = [...restored, ...existing];
      state = state.copyWith(
        accounts: onlineAccounts,
        current:
            state.current ??
            (onlineAccounts.isNotEmpty ? onlineAccounts.first : null),
        offlineAccounts: offline,
      );

      // 反映後の後処理: 通知ラベル永続化（並列）とバッジ用メタのプリフェッチ。
      await Future.wait(restored.map(_persistNotificationLabels));
      await _syncWindowsPushLabels();
      for (final account in restored) {
        ServerMetadataCache.instance.fetch(
          account.key.host,
          preferMisskey: account.adapter is ReactionSupport,
        );
      }
    }

    if (retriableFailures.isNotEmpty) {
      // 起動を待たせないよう、再試行はバックグラウンドへ逃がす（splash は
      // restoreSessions 完走として先へ進み、復帰したアカウントは後から現れる）。
      unawaited(_retryOfflineRestores(retriableFailures));
    }
    return skippedCount;
  }

  /// 1 アカウントを probe し、結果を例外なしのレコードへ畳む。初回の一括復元
  /// （[restoreSessions]）から使う。state は変更しない（反映は呼び出し側で一括）。
  ///
  /// - `account != null` … 復元成功
  /// - `outcome == retriable` … 一時的な到達不能（ネットワーク不通 / サーバー
  ///   5xx）。secret は有効なのでオフライン保持しバックグラウンド再試行へ回す
  ///   (#730 / #792)。
  /// - `outcome == authRevoked` / `giveUp` … auth 失効 / secret 系 / 不明。
  ///   skip して観測する。
  Future<({Account? account, RestoreOutcome? outcome})> _probeForRestore(
    String keyStr,
    Map<String, String> secrets,
  ) async {
    try {
      final account = await _probeAccount(keyStr, secrets);
      return (account: account, outcome: null);
    } catch (e, st) {
      // 一時的な到達不能（host lookup / connection / timeout / サーバー 5xx）の
      // 失敗は、secret は有効なのに probe（getMyself 等）が落ちただけ。これを
      // 「復元不能＝ログアウト」へ降格させない (#730 / #792)。回線ブリップや
      // サーバー再構築時に複数アカウントの getMyself() が同時に失敗→全 skip→
      // 「一斉ログアウト／サーバーごと消えた」に見える事象の根治。secret は
      // 無傷なのでオフライン保持＋背景再試行し、ユーザー操作なしで自動回復
      // させる。auth 失効（401/403）や secret 系・不明は従来通り skip + 観測。
      final outcome = classifyRestoreFailure(e);
      if (outcome == RestoreOutcome.retriable) {
        debugPrint(
          'capsicum: restoreSessions: transient failure for $keyStr, '
          'kept offline and will retry in background: $e',
        );
        return (account: null, outcome: RestoreOutcome.retriable);
      }
      // 復元中の例外を以前は完全に握りつぶしていたが、Linux で Misskey
      // アカウントだけ silently に消える挙動の追跡が不可能になっていた
      // (#496)。debugPrint で起動ログに出し、Sentry にも accountKey 単位で
      // 1 度だけ送る (Keystore 破壊で全アカウント同時失敗するケースで Sentry を
      // 埋めないように)。
      debugLogException('capsicum: account_restore: failed for $keyStr', e, st);
      _reportRestoreOnce(keyStr, e, st);
      return (account: null, outcome: outcome);
    }
  }

  /// secret から 1 アカウントを probe して [Account] を組み立てる（state は
  /// 変更しない）。初回の一括復元（[_probeForRestore] 経由）とリトライ
  /// （[_restoreOne] 経由）の両方から使う。例外は呼び出し側で分類する
  /// （ネットワーク一過性なら再試行、それ以外は skip）。
  Future<Account> _probeAccount(
    String keyStr,
    Map<String, String> secrets,
  ) async {
    final accountKey = AccountKey.fromStorageKey(keyStr);
    final adapter = await accountKey.type.createAdapter(accountKey.host);

    final userSecret = UserSecret(
      accessToken: secrets['access_token']!,
      refreshToken: secrets['refresh_token'],
    );
    final clientSecret = secrets.containsKey('client_id')
        ? ClientSecretData(
            clientId: secrets['client_id']!,
            clientSecret: secrets['client_secret']!,
          )
        : null;

    await adapter.applySecrets(clientSecret, userSecret);

    // 復元プローブをアカウント単位で並列化する (#716)。getMyself /
    // detectTimelineAvailability / mulukhiya 検出 / ソフトウェアバージョン検出は
    // 互いの結果に依存しないため、直列 await の累積（2〜4 本）を最長 1 本ぶんへ
    // 畳む。getMyself 以外はいずれも内部で例外を握る（mulukhiya / version は
    // null 返し、timeline は下の catchError）ので、getMyself が落ちて早期 throw
    // しても未処理例外にはならない。getMyself の例外だけは従来どおり呼び出し側へ
    // 伝播し、ネットワーク一過性 / auth 失効の分類 (#730) に乗せる。
    final userFuture = adapter.getMyself();
    final timelineFuture = adapter is MastodonAdapter
        ? adapter.detectTimelineAvailability().catchError((Object e) {
            debugPrint(
              'capsicum: restoreSessions: detectTimelineAvailability '
              'failed for $keyStr: $e',
            );
          })
        : Future<void>.value();
    final mulukhiyaFuture = _detectMulukhiya(
      accountKey.host,
      token: userSecret.accessToken,
    );
    final softwareVersionFuture = _detectSoftwareVersion(accountKey.host);

    final user = await userFuture;
    await timelineFuture;
    final mulukhiya = await mulukhiyaFuture;
    if (mulukhiya != null) {
      if (adapter is MastodonAdapter) {
        adapter.applyAdminRoleIds(mulukhiya.adminRoleIds);
      } else if (adapter is MisskeyAdapter) {
        adapter.applyAdminRoleIds(mulukhiya.adminRoleIds);
      }
    }
    final softwareVersion = await softwareVersionFuture;

    return Account(
      key: accountKey,
      adapter: adapter,
      user: user,
      userSecret: userSecret,
      clientSecret: clientSecret,
      mulukhiya: mulukhiya,
      softwareVersion: softwareVersion,
    );
  }

  /// 1 アカウントを probe して、成功したら state へ追加する。
  /// バックグラウンド再試行 [_retryOfflineRestores] から使う（初回の一括復元は
  /// [restoreSessions] が [_probeForRestore] で並列化し、まとめて反映する）。
  /// 例外は呼び出し側で分類する（一時的な到達不能なら再試行、それ以外は skip）。
  Future<void> _restoreOne(String keyStr, Map<String, String> secrets) async {
    final account = await _probeAccount(keyStr, secrets);

    // append 直前の最終重複ガード。probe は複数 await をまたぐため、その間に
    // 別経路（手動ログイン / 初回復元）で同一 key が復元されると二重 append に
    // なりうる。ここで再確認する (#730 リトライ経路の防御)。
    if (state.accounts.any((a) => a.key == account.key)) {
      // 既にオンラインなら、オフライン保持が残っていても落としておく。
      _removeOffline(account.key);
      return;
    }

    // 復元成功＝オフライン保持からオンラインへ昇格。offline entry を除去する
    // (#792)。
    state = state.copyWith(
      accounts: [...state.accounts, account],
      current: state.current ?? account,
      offlineAccounts: state.offlineAccounts
          .where((o) => o.key != account.key)
          .toList(),
    );

    await _persistNotificationLabels(account);
    await _syncWindowsPushLabels();

    // Prefetch server metadata for badge display (non-blocking). Misskey
    // フォークの偽 Mastodon 互換版で name/icon が化けないよう型ヒントを渡す (#827)。
    ServerMetadataCache.instance.fetch(
      account.key.host,
      preferMisskey: account.adapter is ReactionSupport,
    );
  }

  /// [key] のオフライン保持を除去する (#792)。昇格・drop・手動削除で使う。
  void _removeOffline(AccountKey key) {
    if (!state.offlineAccounts.any((o) => o.key == key)) return;
    state = state.copyWith(
      offlineAccounts: state.offlineAccounts
          .where((o) => o.key != key)
          .toList(),
    );
  }

  /// [key] のオフライン保持の [OfflineAccount.retrying] フラグを更新する。
  ///
  /// ⚠ **意味が #938 で変わった。** #792 では「背景 backoff がまだ残っている」で、
  /// 使い切ると恒久的に false になる＝「もう自動では戻らない」の印だった。
  /// 背景再試行が打ち切りを持たなくなったので、いまは **「この瞬間 probe が
  /// 走っている」** を表す（周回の合間は false）。UI の「再試行中…」/「接続を
  /// 待っています」はこの粒度で出し分ける。
  void _markOfflineRetrying(AccountKey key, bool retrying) {
    final idx = state.offlineAccounts.indexWhere((o) => o.key == key);
    if (idx < 0) return;
    final updated = [...state.offlineAccounts];
    updated[idx] = updated[idx].copyWith(retrying: retrying);
    state = state.copyWith(offlineAccounts: updated);
  }

  /// 一時的な到達不能で初回復元に失敗し、オフライン保持したアカウントを、
  /// 回線 / サーバー復帰を待ってバックグラウンドで再試行する (#730 / #792 / #938)。
  ///
  /// 成功すればオンラインへ昇格してユーザー操作なしで自動回復する（offline entry は
  /// [_restoreOne] が除去）。手動ログイン等で既に復元済みのものはスキップ。
  /// auth 失効（401/403）等へ転じたら再ログイン扱いで offline から drop + 観測。
  ///
  /// ⚠ **このループは打ち切らない (#938)。** 到達不能なアカウントが残っている
  /// 限り [_offlineRetrySteadyInterval] で回り続ける。理由はそちらの doc。
  Future<void> _retryOfflineRestores(
    List<({String keyStr, Map<String, String> secrets})> pending,
  ) async {
    if (_offlineRetryLoopRunning) {
      // 既に回っているループへ任せる。二重に走らせると probe が恒久的に
      // 2 倍になる（打ち切りが無いため自然には収束しない）。
      return;
    }
    _offlineRetryLoopRunning = true;
    try {
      var remaining = pending;
      var attempt = 0;
      while (remaining.isNotEmpty && !_disposed) {
        final delay = offlineRetryDelay(attempt);
        attempt++;
        await Future<void>.delayed(delay);
        if (_disposed) return;

        final stillFailing = <({String keyStr, Map<String, String> secrets})>[];
        for (final item in remaining) {
          // 別経路（手動ログイン等）で既に復元済みなら何もしない。
          final alreadyRestored = state.accounts.any(
            (a) => a.key.toStorageKey() == item.keyStr,
          );
          if (alreadyRestored) continue;
          // この周回で実際に probe している間だけ「再試行中…」を出す (#938)。
          _markOfflineByKeyStr(item.keyStr, retrying: true);
          try {
            await _restoreOne(item.keyStr, item.secrets);
          } catch (e, st) {
            if (classifyRestoreFailure(e) == RestoreOutcome.retriable) {
              stillFailing.add(item); // まだ到達不能。次の間隔で再試行。
              // 次の周回まで待ちに入るので「再試行中…」は下ろす。
              _markOfflineByKeyStr(item.keyStr, retrying: false);
            } else {
              // auth 失効（401/403）等へ転じたら再ログイン扱い。offline から
              // drop して観測する（一覧に残すと復帰しないゾンビになる）。
              debugPrint(
                'capsicum: account_restore: retry gave up for '
                '${item.keyStr}: $e',
              );
              _dropOfflineByKeyStr(item.keyStr);
              _reportRestoreOnce(item.keyStr, e, st);
            }
          }
        }
        remaining = stillFailing;

        // ramp-up を使い切った時点＝**52 秒以内には戻らなかった**という観測
        // 上の節目。#792 はここで打ち切っていたが、#938 で継続へ変えたので
        // 「打ち切り」ではなく marker として 1 度だけ記録する。per-process
        // dedup があるので、以降の周回では二重に上がらない。
        if (attempt == kOfflineRetryRampUp.length && remaining.isNotEmpty) {
          debugPrint(
            'capsicum: restoreSessions: ${remaining.length} account(s) still '
            'unreachable after ramp-up; keeping retry loop running '
            '(${kOfflineRetrySteadyInterval.inSeconds}s interval)',
          );
          for (final item in remaining) {
            _reportRestoreExhaustedOnce(item.keyStr);
          }
        }
      }
    } finally {
      _offlineRetryLoopRunning = false;
    }
  }

  /// フォアグラウンド復帰を契機に、オフライン保持中のアカウントを即座に
  /// 再試行する (#938)。
  ///
  /// 定常間隔は 60 秒あり、またモバイルでは背面にいる間タイマーが進まない。
  /// オフライン中はアプリを閉じていることも多いので、この契機がいちばん効く。
  /// 復元済み / オフライン無しなら何もしない。
  void refreshOfflineRestoresOnResume() {
    if (state.offlineAccounts.isEmpty) return;
    unawaited(retryOfflineRestores());
  }

  /// storage key を [AccountKey] に parse する。scheme 不正な legacy / 破損 key は
  /// null（呼び出し側は skip する）。
  AccountKey? _tryParseStorageKey(String keyStr) {
    try {
      return AccountKey.fromStorageKey(keyStr);
    } catch (_) {
      return null;
    }
  }

  /// keyStr（storage key）から offline entry を除去する。破損 key は無視。
  void _dropOfflineByKeyStr(String keyStr) {
    try {
      _removeOffline(AccountKey.fromStorageKey(keyStr));
    } catch (_) {
      // parse 不能 key は offline 表現を持たないので何もしない。
    }
  }

  /// keyStr（storage key）から offline entry の retrying フラグを更新する。
  void _markOfflineByKeyStr(String keyStr, {required bool retrying}) {
    try {
      _markOfflineRetrying(AccountKey.fromStorageKey(keyStr), retrying);
    } catch (_) {
      // parse 不能 key は無視。
    }
  }

  /// オフライン保持中のアカウントを即時に再試行する (#792)。
  /// オフラインプレースホルダ / 切替 UI の「再試行」ボタンと、フォアグラウンド
  /// 復帰 ([refreshOfflineRestoresOnResume]) から呼ぶ。secret は state に持たず
  /// storage から読み直す。成功すればオンラインへ昇格する。
  ///
  /// 進行中の呼び出しがあれば no-op。#938 でユーザー操作以外（復帰）からも
  /// 叩くようになったので、連続した resume やボタン連打で同じ probe が
  /// 積み上がらないようにする。
  Future<void> retryOfflineRestores() async {
    if (_manualRetryRunning) return;
    _manualRetryRunning = true;
    try {
      await _retryOfflineRestoresNow();
    } finally {
      _manualRetryRunning = false;
    }
  }

  bool _manualRetryRunning = false;

  Future<void> _retryOfflineRestoresNow() async {
    final storage = ref.read(accountStorageProvider);
    // 反復中に state.offlineAccounts が変化するのでスナップショットを取る。
    final targets = [...state.offlineAccounts];
    for (final offline in targets) {
      final keyStr = offline.key.toStorageKey();
      if (state.accounts.any((a) => a.key == offline.key)) {
        _removeOffline(offline.key);
        continue;
      }
      _markOfflineRetrying(offline.key, true);
      Map<String, String>? secrets;
      try {
        secrets = await storage.getSecrets(keyStr);
      } on TransientSecretUnavailableException {
        // まだ読めない（ロック継続中）。drop せず offline のまま次の契機
        // （resume / 再試行ボタン）を待つ (#959)。null（secret 消失）とは違い、
        // 諦めない。
        _markOfflineRetrying(offline.key, false);
        continue;
      }
      if (secrets == null) {
        // secret が消えていれば復元不能。drop + 観測。
        _dropOfflineByKeyStr(keyStr);
        _reportNullSecretSkipOnce(keyStr);
        continue;
      }
      try {
        await _restoreOne(keyStr, secrets);
      } catch (e, st) {
        if (classifyRestoreFailure(e) == RestoreOutcome.retriable) {
          _markOfflineRetrying(offline.key, false);
        } else {
          _dropOfflineByKeyStr(keyStr);
          _reportRestoreOnce(keyStr, e, st);
        }
      }
    }
  }

  /// オフライン保持中のアカウントをユーザー操作で一覧から削除する (#792)。
  /// secret も storage から消す（＝明示ログアウト相当）。
  Future<void> removeOfflineAccount(AccountKey key) async {
    final storage = ref.read(accountStorageProvider);
    await storage.removeAccount(key.toStorageKey());
    // 明示ログアウト相当なので、TL キャッシュ (#890) も [logout] と同じく捨てる。
    // contextKey が一致しなければ使われない作りだが、消したアカウントの投稿を
    // 端末に残す理由が無い点は logout と変わらない。
    await TimelineCache.clear();
    _removeOffline(key);
    await _syncWindowsPushLabels();
  }

  static final Set<String> _reportedRestoreErrors = {};

  /// テストの tearDown 等で per-test 汚染を避けるための reset hook (#516)。
  /// 本番経路では呼ばれず、Notifier が dispose-recreate されても dedup を
  /// 永続化するという仕様自体は維持する。
  @visibleForTesting
  static void resetReportedRestoreErrors() => _reportedRestoreErrors.clear();

  static void _reportRestoreOnce(String accountKey, Object e, StackTrace st) {
    final dedupKey = '$accountKey:${e.runtimeType}';
    if (!_reportedRestoreErrors.add(dedupKey)) return;
    try {
      // accountKey 全体 (host_username) を tag に出すと Sentry プロジェクトの
      // アクセス制御次第で運用者以外にユーザ名が見えうる (#500)。tag は host
      // のみに限定し、username は de-identification 用ハッシュに丸めて
      // 別 tag に出す。dedup には fingerprint で対応。
      //
      // AccountKey.fromStorageKey は scheme 不正な legacy / 破損 key で
      // StateError を投げる。parse 失敗時は tag を諦めて元の例外を上げ続ける
      // (#524)。観測ロストよりは parse 失敗マーカ付きで Sentry に届けるほうが
      // 価値が高いと判断。
      AccountKey? parsed;
      try {
        parsed = AccountKey.fromStorageKey(accountKey);
      } catch (_) {
        parsed = null;
      }
      Sentry.captureException(
        e,
        stackTrace: st,
        withScope: (scope) {
          // null 経路 (`_reportNullSecretSkipOnce`) と区別するための経路タグ。
          scope.setTag('account_restore.path', 'exception');
          if (parsed != null) {
            scope.setTag('account_restore.host', parsed.host);
            scope.setTag(
              'account_restore.user_hash',
              hashForSentryTag(parsed.username),
            );
          } else {
            scope.setTag('account_restore.key_parse', 'failed');
          }
          scope.fingerprint = ['account_restore', e.runtimeType.toString()];
        },
      );
    } catch (_) {
      // Sentry 自体が起動前 / 失敗するケースでも本筋を止めない。
    }
  }

  /// secret が例外なく欠落していた (`getSecrets` の raw==null) ためアカウントを
  /// skip した際に、軽量メッセージを per-process で 1 度だけ送る (#704)。
  ///
  /// 例外経路 (`_reportRestoreOnce`) と同じ de-identification ポリシーに従う:
  /// tag は host のみ、username は [hashForSentryTag] でハッシュ化 (#500)。
  /// dedup は例外経路と同じ [_reportedRestoreErrors] を `:null_secret` 接尾辞で
  /// 共用し、Keystore 一括喪失で全アカウント同時 skip しても Sentry を
  /// 埋めない (#337-B と同じ per-process dedup)。
  static void _reportNullSecretSkipOnce(String accountKey) {
    final dedupKey = '$accountKey:null_secret';
    if (!_reportedRestoreErrors.add(dedupKey)) return;
    try {
      // AccountKey.fromStorageKey は破損 key で StateError を投げる。parse 失敗
      // 時は tag を諦めて parse 失敗マーカ付きで送る (#524 と同方針)。
      AccountKey? parsed;
      try {
        parsed = AccountKey.fromStorageKey(accountKey);
      } catch (_) {
        parsed = null;
      }
      Sentry.captureMessage(
        'account_restore: secret missing (null path), account skipped',
        level: SentryLevel.warning,
        withScope: (scope) {
          scope.setTag('account_restore.path', 'null_secret');
          if (parsed != null) {
            scope.setTag('account_restore.host', parsed.host);
            scope.setTag(
              'account_restore.user_hash',
              hashForSentryTag(parsed.username),
            );
          } else {
            scope.setTag('account_restore.key_parse', 'failed');
          }
          scope.fingerprint = ['account_restore', 'null_secret'];
        },
      );
    } catch (_) {
      // Sentry 自体が起動前 / 失敗するケースでも本筋を止めない。
    }
  }

  /// ネットワーク一過性として再試行を尽くしても復元できなかったアカウントを
  /// per-process で 1 度だけ観測する (#730)。例外経路 (`_reportRestoreOnce`) /
  /// null 経路 (`_reportNullSecretSkipOnce`) と同じ de-identification ポリシー
  /// （tag は host のみ・username はハッシュ・dedup は [_reportedRestoreErrors]
  /// を `:network_exhausted` 接尾辞で共用）に従う。一過性前提の握り潰しが恒久
  /// 障害を覆い隠していないか、本番 Sentry で頻度・規模を把握するため。
  static void _reportRestoreExhaustedOnce(String accountKey) {
    final dedupKey = '$accountKey:network_exhausted';
    if (!_reportedRestoreErrors.add(dedupKey)) return;
    try {
      AccountKey? parsed;
      try {
        parsed = AccountKey.fromStorageKey(accountKey);
      } catch (_) {
        parsed = null;
      }
      Sentry.captureMessage(
        'account_restore: still unreachable after retries (network exhausted)',
        level: SentryLevel.warning,
        withScope: (scope) {
          scope.setTag('account_restore.path', 'network_exhausted');
          if (parsed != null) {
            scope.setTag('account_restore.host', parsed.host);
            scope.setTag(
              'account_restore.user_hash',
              hashForSentryTag(parsed.username),
            );
          } else {
            scope.setTag('account_restore.key_parse', 'failed');
          }
          scope.fingerprint = ['account_restore', 'network_exhausted'];
        },
      );
    } catch (_) {
      // Sentry 自体が起動前 / 失敗するケースでも本筋を止めない。
    }
  }
}

final accountManagerProvider =
    NotifierProvider<AccountManagerNotifier, AccountManagerState>(
      AccountManagerNotifier.new,
    );

/// SplashScreen の `_restoreSessions()` が完走したかどうか。
///
/// 通知タップ routing（[main._routeToNotificationsTab]）が
/// 「accounts に 1 件あれば restore 完了」と誤判定しないための明示的な
/// signal。restoreSessions は 1 アカウントずつ state を更新しながら進む
/// ため、途中で通知 routing を走らせると宛先アカウントがまだ未登録で
/// 取りこぼす。
final sessionsRestoredProvider = StateProvider<bool>((ref) => false);

final accountStorageProvider = Provider<AccountStorage>(
  (ref) => AccountStorage(),
);

/// Convenience provider for the currently selected account.
final currentAccountProvider = Provider<Account?>((ref) {
  return ref.watch(accountManagerProvider).current;
});

/// 到達不能でオフライン保持中のアカウント一覧 (#792)。
final offlineAccountsProvider = Provider<List<OfflineAccount>>((ref) {
  return ref.watch(accountManagerProvider).offlineAccounts;
});

/// Convenience provider for the current adapter.
final currentAdapterProvider = Provider<DecentralizedBackendAdapter?>((ref) {
  return ref.watch(currentAccountProvider)?.adapter;
});

/// Convenience provider for the current account's mulukhiya service.
final currentMulukhiyaProvider = Provider<MulukhiyaService?>((ref) {
  return ref.watch(currentAccountProvider)?.mulukhiya;
});

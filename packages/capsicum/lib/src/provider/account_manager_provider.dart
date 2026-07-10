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
import '../service/wns_service.dart';
import '../util/login_error.dart';
import '../util/sentry_tag_hash.dart';

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

  AccountManagerState copyWith({
    List<Account>? accounts,
    Account? current,
    List<OfflineAccount>? offlineAccounts,
  }) => AccountManagerState(
    accounts: accounts ?? this.accounts,
    current: current ?? this.current,
    offlineAccounts: offlineAccounts ?? this.offlineAccounts,
  );
}

class AccountManagerNotifier extends Notifier<AccountManagerState> {
  @override
  AccountManagerState build() => const AccountManagerState();

  /// host ごとのモロヘイヤ自動再検出の最終実行時刻。フォアグラウンド復帰 / ドロワー
  /// 表示のたびに `/about` を叩かないよう TTL で間引く (#775)。
  final _mulukhiyaAutoRefreshedAt = <String, DateTime>{};
  static const _mulukhiyaAutoRefreshTtl = Duration(hours: 1);

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
    state = AccountManagerState(
      accounts: newAccounts,
      current: enriched,
      offlineAccounts: offline,
    );

    // Prefetch server metadata for badge display (non-blocking).
    ServerMetadataCache.instance.fetch(account.key.host);

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
    state = AccountManagerState(
      accounts: reordered,
      current: account,
      offlineAccounts: state.offlineAccounts,
    );

    // Persist MRU order in background (failure is non-fatal).
    final storage = ref.read(accountStorageProvider);
    storage.touchAccount(account.key.toStorageKey()).catchError((_) {});

    // Clear unread notification count for the account we're switching to.
    BackgroundNotificationService.clearUnreadCount(account.key.toStorageKey());

    // Prefetch server metadata for badge display (non-blocking).
    ServerMetadataCache.instance.fetch(account.key.host);
  }

  void updateCurrentUser(User user) {
    final current = state.current;
    if (current == null) return;
    final updated = current.copyWithUser(user);
    final accounts = state.accounts
        .map((a) => a.key == updated.key ? updated : a)
        .toList();
    state = AccountManagerState(
      accounts: accounts,
      current: updated,
      offlineAccounts: state.offlineAccounts,
    );
  }

  Future<void> logout(Account account) async {
    // プッシュ通知登録解除（ベストエフォート）。
    PushRegistrationService.unregisterAccount(account);
    await NotificationLabelCache.remove(_notificationLabelKey(account));

    final storage = ref.read(accountStorageProvider);
    await storage.removeAccount(account.key.toStorageKey());

    final remaining = state.accounts
        .where((a) => a.key != account.key)
        .toList();

    final next = (state.current?.key == account.key)
        ? (remaining.isNotEmpty ? remaining.first : null)
        : state.current;

    state = AccountManagerState(
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
    final current = state.current;
    if (current == null) return false;

    final mulukhiya = await _detectMulukhiya(
      current.key.host,
      token: current.userSecret.accessToken,
    );
    if (mulukhiya == null) return false;

    if (current.adapter is MastodonAdapter) {
      (current.adapter as MastodonAdapter).applyAdminRoleIds(
        mulukhiya.adminRoleIds,
      );
    } else if (current.adapter is MisskeyAdapter) {
      (current.adapter as MisskeyAdapter).applyAdminRoleIds(
        mulukhiya.adminRoleIds,
      );
    }
    final updated = current.copyWithMulukhiya(mulukhiya);
    final accounts = state.accounts
        .map((a) => a.key == updated.key ? updated : a)
        .toList();
    state = AccountManagerState(
      accounts: accounts,
      current: updated,
      offlineAccounts: state.offlineAccounts,
    );
    // 手動再検出も自動再検出 (#775) の TTL を消費させ、直後のフォアグラウンド
    // 復帰で二重に `/about` を叩かないようにする。
    _mulukhiyaAutoRefreshedAt[current.key.host] = DateTime.now();
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
    final metadata = await ServerMetadataCache.instance.fetch(
      host,
      forceRefresh: force,
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
    state = AccountManagerState(
      accounts: accounts,
      current: state.current?.key == updated.key ? updated : state.current,
      offlineAccounts: state.offlineAccounts,
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
      debugPrint('capsicum: software version detection error on $host: $e');
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
      final dio = Dio(BaseOptions(connectTimeout: kNetworkConnectTimeout));
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
      debugPrint('capsicum: mulukhiya detection error on $host: $e');
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

    // secret を読み出せたアカウントだけを probe 対象に集める。順序は
    // getAccountKeys（＝MRU）を保持し、後段の一括反映でこの並びを使う。
    final entries = <({String keyStr, Map<String, String> secrets})>[];
    for (final keyStr in keys) {
      final secrets = await storage.getSecrets(keyStr);
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
        AccountKey? key;
        try {
          key = AccountKey.fromStorageKey(entries[i].keyStr);
        } catch (_) {
          key = null;
        }
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

    if (restored.isNotEmpty || offline.isNotEmpty) {
      // MRU 順を保ったまま一括反映する。current は先頭（＝MRU 先頭）。splash 中は
      // 通常 state は空だが、万一別経路が先に追加したアカウントがあれば温存する。
      final existing = state.accounts
          .where((a) => restored.every((r) => r.key != a.key))
          .toList();
      final onlineAccounts = [...restored, ...existing];
      state = AccountManagerState(
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
        ServerMetadataCache.instance.fetch(account.key.host);
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
      debugPrint('capsicum: account_restore: failed for $keyStr: $e\n$st');
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
    state = AccountManagerState(
      accounts: [...state.accounts, account],
      current: state.current ?? account,
      offlineAccounts: state.offlineAccounts
          .where((o) => o.key != account.key)
          .toList(),
    );

    await _persistNotificationLabels(account);
    await _syncWindowsPushLabels();

    // Prefetch server metadata for badge display (non-blocking).
    ServerMetadataCache.instance.fetch(account.key.host);
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

  /// [key] のオフライン保持の [OfflineAccount.retrying] フラグを更新する
  /// (#792)。背景リトライを尽くした後は false（手動再試行は可能）。
  void _markOfflineRetrying(AccountKey key, bool retrying) {
    final idx = state.offlineAccounts.indexWhere((o) => o.key == key);
    if (idx < 0) return;
    final updated = [...state.offlineAccounts];
    updated[idx] = updated[idx].copyWith(retrying: retrying);
    state = state.copyWith(offlineAccounts: updated);
  }

  /// 一時的な到達不能で初回復元に失敗し、オフライン保持したアカウントを、
  /// 回線 / サーバー復帰を待ってバックグラウンドで再試行する (#730 / #792)。
  /// 短い backoff を数回かけ、成功すればオンラインへ昇格してユーザー操作なしで
  /// 自動回復する（offline entry は [_restoreOne] が除去）。手動ログイン等で
  /// 既に復元済みのものはスキップ。auth 失効（401/403）等へ転じたら再ログイン
  /// 扱いで offline から drop + 観測。全 backoff 後も不通なら offline 保持のまま
  /// `retrying=false` にし（手動再試行は可能）、観測を 1 度残す。
  Future<void> _retryOfflineRestores(
    List<({String keyStr, Map<String, String> secrets})> pending,
  ) async {
    const delays = [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 30),
    ];
    var remaining = pending;
    for (final delay in delays) {
      if (remaining.isEmpty) return;
      await Future<void>.delayed(delay);
      final stillFailing = <({String keyStr, Map<String, String> secrets})>[];
      for (final item in remaining) {
        // 別経路（手動ログイン等）で既に復元済みなら何もしない。
        final alreadyRestored = state.accounts.any(
          (a) => a.key.toStorageKey() == item.keyStr,
        );
        if (alreadyRestored) continue;
        try {
          await _restoreOne(item.keyStr, item.secrets);
        } catch (e, st) {
          if (classifyRestoreFailure(e) == RestoreOutcome.retriable) {
            stillFailing.add(item); // まだ到達不能。次の backoff で再試行。
          } else {
            // auth 失効（401/403）等へ転じたら再ログイン扱い。offline から
            // drop して観測する（一覧に残すと復帰しないゾンビになる）。
            debugPrint(
              'capsicum: account_restore: retry gave up for ${item.keyStr}: $e',
            );
            _dropOfflineByKeyStr(item.keyStr);
            _reportRestoreOnce(item.keyStr, e, st);
          }
        }
      }
      remaining = stillFailing;
    }
    if (remaining.isNotEmpty) {
      debugPrint(
        'capsicum: restoreSessions: ${remaining.length} account(s) still '
        'unreachable after retries; kept offline (user can retry / re-login)',
      );
      // 全 backoff 後も不通＝「一過性」前提が外れて恒久障害だった可能性がある。
      // #792 では消さずオフライン保持したまま retrying=false にして「再試行
      // 中」表示を止める（手動再試行 / 再ログインは可能）。#730 と同じく、
      // 握り潰しが恒久障害を覆い隠さないよう per-process dedup で 1 度だけ観測。
      for (final item in remaining) {
        _markOfflineByKeyStr(item.keyStr, retrying: false);
        _reportRestoreExhaustedOnce(item.keyStr);
      }
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

  /// オフライン保持中のアカウントを、ユーザー操作で即時に再試行する (#792)。
  /// オフラインプレースホルダ / 切替 UI の「再試行」から呼ぶ。secret は state に
  /// 持たず storage から読み直す。成功すればオンラインへ昇格する。
  Future<void> retryOfflineRestores() async {
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
      final secrets = await storage.getSecrets(keyStr);
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

import 'dart:async';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../constants.dart';
import '../model/account.dart';
import '../model/account_key.dart';
import '../service/account_storage.dart';
import '../service/background_notification_service.dart';
import '../service/notification_label_cache.dart';
import '../service/push_registration_service.dart';
import '../service/server_metadata_cache.dart';
import '../util/login_error.dart';
import '../util/sentry_tag_hash.dart';

/// State: list of accounts + currently selected account.
class AccountManagerState {
  final List<Account> accounts;
  final Account? current;

  const AccountManagerState({this.accounts = const [], this.current});

  AccountManagerState copyWith({List<Account>? accounts, Account? current}) =>
      AccountManagerState(
        accounts: accounts ?? this.accounts,
        current: current ?? this.current,
      );
}

class AccountManagerNotifier extends Notifier<AccountManagerState> {
  @override
  AccountManagerState build() => const AccountManagerState();

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
    state = AccountManagerState(accounts: newAccounts, current: enriched);

    // Prefetch server metadata for badge display (non-blocking).
    ServerMetadataCache.instance.fetch(account.key.host);

    // 通知ラベル（ブースト/投稿）を FCM バックグラウンド isolate 用に焼く。
    // registerAccount より先に完了させる: 登録直後に届く最初のプッシュが
    // ラベル未保存のまま既定値（ブースト/投稿）に化けないように。
    await _persistNotificationLabels(enriched);

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
    state = AccountManagerState(accounts: reordered, current: account);

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
    state = AccountManagerState(accounts: accounts, current: updated);
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

    state = AccountManagerState(accounts: remaining, current: next);
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
    state = AccountManagerState(accounts: accounts, current: updated);
    await _persistNotificationLabels(updated);
    return true;
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
    final mulukhiya = account.mulukhiya;
    final reblog =
        mulukhiya?.reblogLabel ??
        (account.adapter is ReactionSupport ? 'リノート' : 'ブースト');
    final post = mulukhiya?.postLabel ?? '投稿';
    await NotificationLabelCache.save(
      _notificationLabelKey(account),
      reblogLabel: reblog,
      postLabel: post,
    );
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
    // ネットワーク一過性で落ちたアカウント（secret は有効）。ループ後に
    // バックグラウンドで再試行する (#730)。
    final transientFailures = <({String keyStr, Map<String, String> secrets})>[];

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

      try {
        await _restoreOne(keyStr, secrets);
      } catch (e, st) {
        // ネットワーク一過性（host lookup / connection / timeout）の失敗は、
        // secret は有効なのに probe（getMyself 等）が落ちただけ。これを
        // 「復元不能＝ログアウト」へ降格させない (#730)。回線ブリップ時に複数
        // アカウントの getMyself() が同時に失敗→全 skip→「一斉ログアウト」に
        // 見える事象の根治。secret は無傷なのでバックグラウンドで再試行し、
        // ユーザー操作なしで自動回復させる。auth 失効（401=server 応答）や
        // secret 系・不明はこれまで通り skip + 観測する。
        if (classifyLoginFailure(e).kind == LoginFailureKind.network) {
          debugPrint(
            'capsicum: restoreSessions: transient network for $keyStr, '
            'will retry in background: $e',
          );
          transientFailures.add((keyStr: keyStr, secrets: secrets));
          continue;
        }
        // 復元中の例外を以前は完全に握りつぶしていたが、Linux で
        // Misskey アカウントだけ silently に消える挙動の追跡が不可能に
        // なっていた (#496)。debugPrint で起動ログに出し、Sentry にも
        // accountKey 単位で 1 度だけ送る (Keystore 破壊で全アカウント
        // 同時失敗するケースで Sentry を埋めないように)。
        debugPrint('capsicum: account_restore: failed for $keyStr: $e\n$st');
        _reportRestoreOnce(keyStr, e, st);
        skippedCount++;
        continue;
      }
    }

    if (transientFailures.isNotEmpty) {
      // 起動を待たせないよう、再試行はバックグラウンドへ逃がす（splash は
      // restoreSessions 完走として先へ進み、復帰したアカウントは後から現れる）。
      unawaited(_retryTransientRestores(transientFailures));
    }
    return skippedCount;
  }

  /// 1 アカウントを secret から復元し、成功したら state へ追加する。
  /// [restoreSessions] の初回ループと [_retryTransientRestores] の両方から使う。
  /// 例外は呼び出し側で分類する（ネットワーク一過性なら再試行、それ以外は skip）。
  Future<void> _restoreOne(String keyStr, Map<String, String> secrets) async {
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
    final user = await adapter.getMyself();

    // Detect timeline availability (non-blocking).
    if (adapter is MastodonAdapter) {
      try {
        await adapter.detectTimelineAvailability();
      } catch (e) {
        debugPrint(
          'capsicum: restoreSessions: detectTimelineAvailability '
          'failed for $keyStr: $e',
        );
      }
    }

    final mulukhiya = await _detectMulukhiya(
      accountKey.host,
      token: userSecret.accessToken,
    );
    if (mulukhiya != null) {
      if (adapter is MastodonAdapter) {
        adapter.applyAdminRoleIds(mulukhiya.adminRoleIds);
      } else if (adapter is MisskeyAdapter) {
        adapter.applyAdminRoleIds(mulukhiya.adminRoleIds);
      }
    }
    final softwareVersion = await _detectSoftwareVersion(accountKey.host);

    final account = Account(
      key: accountKey,
      adapter: adapter,
      user: user,
      userSecret: userSecret,
      clientSecret: clientSecret,
      mulukhiya: mulukhiya,
      softwareVersion: softwareVersion,
    );

    final newAccounts = [...state.accounts, account];
    state = AccountManagerState(
      accounts: newAccounts,
      current: state.current ?? account,
    );

    await _persistNotificationLabels(account);

    // Prefetch server metadata for badge display (non-blocking).
    ServerMetadataCache.instance.fetch(accountKey.host);
  }

  /// ネットワーク一過性で初回復元に失敗したアカウントを、回線復帰を待って
  /// バックグラウンドで再試行する (#730)。短い backoff を数回かけ、成功すれば
  /// state に現れてユーザー操作なしで自動回復する。手動ログイン等で既に
  /// 復元済みのものはスキップ。ネットワーク以外（auth 失効等）へ転じたら諦めて
  /// 観測。全 backoff 後も不通なら観測のみ残す（ユーザーは手動で再ログイン可能）。
  Future<void> _retryTransientRestores(
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
      final stillFailing =
          <({String keyStr, Map<String, String> secrets})>[];
      for (final item in remaining) {
        // 別経路（手動ログイン等）で既に復元済みなら何もしない。
        final alreadyRestored = state.accounts.any(
          (a) => a.key.toStorageKey() == item.keyStr,
        );
        if (alreadyRestored) continue;
        try {
          await _restoreOne(item.keyStr, item.secrets);
        } catch (e, st) {
          if (classifyLoginFailure(e).kind == LoginFailureKind.network) {
            stillFailing.add(item); // まだ不通。次の backoff で再試行。
          } else {
            // ネットワーク以外（auth 失効等）へ転じたら諦めて観測する。
            debugPrint(
              'capsicum: account_restore: retry gave up for ${item.keyStr}: $e',
            );
            _reportRestoreOnce(item.keyStr, e, st);
          }
        }
      }
      remaining = stillFailing;
    }
    if (remaining.isNotEmpty) {
      debugPrint(
        'capsicum: restoreSessions: ${remaining.length} account(s) still '
        'unreachable after retries; user can re-login manually',
      );
    }
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

/// Convenience provider for the current adapter.
final currentAdapterProvider = Provider<DecentralizedBackendAdapter?>((ref) {
  return ref.watch(currentAccountProvider)?.adapter;
});

/// Convenience provider for the current account's mulukhiya service.
final currentMulukhiyaProvider = Provider<MulukhiyaService?>((ref) {
  return ref.watch(currentAccountProvider)?.mulukhiya;
});

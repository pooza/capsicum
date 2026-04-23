import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import '../model/account.dart';
import '../model/account_key.dart';
import '../service/account_storage.dart';
import '../service/background_notification_service.dart';
import '../service/notification_label_cache.dart';
import '../service/push_registration_service.dart';
import '../service/server_metadata_cache.dart';

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
      } catch (_) {}
    }

    // Detect mulukhiya on the server (non-blocking — failure is fine).
    final mulukhiya = await _detectMulukhiya(account.key.host);
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
    _persistNotificationLabels(enriched);

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
    NotificationLabelCache.remove(_notificationLabelKey(account));

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

    final mulukhiya = await _detectMulukhiya(current.key.host);
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
    _persistNotificationLabels(updated);
    return true;
  }

  /// [Account] を `username@host` 形式に直す。capsicum-relay が push payload
  /// に載せる `account` 文字列・[NotificationLabelCache] のキー・通知ルート
  /// 解決用と全経路で同一フォーマットを使う。
  static String _notificationLabelKey(Account account) =>
      '${account.key.username}@${account.key.host}';

  /// [Account] から「ブースト/リノート/リキュア！」「投稿」ラベルを解決し、
  /// FCM バックグラウンド isolate からも参照できるよう永続化する。
  /// 解決ロジックは [main._resolveReblogLabelForAccount] と揃っている必要が
  /// ある（Mastodon=ブースト、Misskey=リノート、mulukhiya があれば上書き）。
  void _persistNotificationLabels(Account account) {
    final mulukhiya = account.mulukhiya;
    final reblog = mulukhiya?.reblogLabel ??
        (account.adapter is ReactionSupport ? 'リノート' : 'ブースト');
    final post = mulukhiya?.postLabel ?? '投稿';
    NotificationLabelCache.save(
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
    } catch (_) {
      return null;
    }
  }

  /// Detect mulukhiya on the given host.
  Future<MulukhiyaService?> _detectMulukhiya(String host) async {
    try {
      final dio = Dio(BaseOptions(connectTimeout: kNetworkConnectTimeout));
      final mulukhiya = await MulukhiyaService.detect(dio, host);
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

    for (final keyStr in keys) {
      final secrets = await storage.getSecrets(keyStr);
      if (secrets == null) {
        skippedCount++;
        continue;
      }

      try {
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
          } catch (_) {}
        }

        final mulukhiya = await _detectMulukhiya(accountKey.host);
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

        _persistNotificationLabels(account);

        // Prefetch server metadata for badge display (non-blocking).
        ServerMetadataCache.instance.fetch(accountKey.host);
      } catch (_) {
        skippedCount++;
        continue;
      }
    }
    return skippedCount;
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

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/account.dart';
import '../model/account_key.dart';
import '../service/account_storage.dart';
import '../service/background_notification_service.dart';
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

  /// Detect software version via NodeInfo on the given host.
  Future<String?> _detectSoftwareVersion(String host) async {
    try {
      final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 5)));
      final probe = await probeInstance(dio, host);
      return probe?.softwareVersion;
    } catch (_) {
      return null;
    }
  }

  /// Detect mulukhiya on the given host.
  Future<MulukhiyaService?> _detectMulukhiya(String host) async {
    try {
      final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 5)));
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
  Future<void> restoreSessions() async {
    final storage = ref.read(accountStorageProvider);
    final keys = await storage.getAccountKeys();

    for (final keyStr in keys) {
      final secrets = await storage.getSecrets(keyStr);
      if (secrets == null) continue;

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

        // Prefetch server metadata for badge display (non-blocking).
        ServerMetadataCache.instance.fetch(accountKey.host);
      } catch (_) {
        // Skip failed restorations
        continue;
      }
    }
  }
}

final accountManagerProvider =
    NotifierProvider<AccountManagerNotifier, AccountManagerState>(
      AccountManagerNotifier.new,
    );

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

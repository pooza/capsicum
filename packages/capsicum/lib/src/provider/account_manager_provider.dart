import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/account.dart';
import '../model/account_key.dart';
import '../service/account_storage.dart';

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

    // Detect mulukhiya on the server (non-blocking — failure is fine).
    final mulukhiya = await _detectMulukhiya(account.key.host);
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

    final newAccounts = [...state.accounts, enriched];
    state = AccountManagerState(
      accounts: newAccounts,
      current: state.current ?? enriched,
    );
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

        final mulukhiya = await _detectMulukhiya(accountKey.host);
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

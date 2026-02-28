import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/account.dart';
import '../model/account_key.dart';
import '../service/account_storage.dart';

/// State: list of accounts + currently selected account.
class AccountManagerState {
  final List<Account> accounts;
  final Account? current;

  const AccountManagerState({this.accounts = const [], this.current});

  AccountManagerState copyWith({
    List<Account>? accounts,
    Account? current,
  }) =>
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

    final newAccounts = [...state.accounts, account];
    state = AccountManagerState(
      accounts: newAccounts,
      current: state.current ?? account,
    );
  }

  void switchAccount(Account account) {
    state = state.copyWith(current: account);
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
        final clientSecret =
            secrets.containsKey('client_id')
                ? ClientSecretData(
                  clientId: secrets['client_id']!,
                  clientSecret: secrets['client_secret']!,
                )
                : null;

        await adapter.applySecrets(clientSecret, userSecret);
        final user = await adapter.getMyself();

        final account = Account(
          key: accountKey,
          adapter: adapter,
          user: user,
          userSecret: userSecret,
          clientSecret: clientSecret,
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

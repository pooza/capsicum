import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/widget/cross_account_boost.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1279: 「別アカウントでブースト / リノート」の候補は、**今その投稿を見ている
/// アカウント**を除いたもの。
///
/// デッキのカラムは `currentAccountProvider` を上書きして自分のアカウントで
/// 動く。候補の計算だけがアプリ全体の「現在のアカウント」を直接読んでいたので、
/// 出るべきアカウントが欠け、カラム自身が候補に出ていた。
class _Adapter extends Mock implements DecentralizedBackendAdapter {}

Account _account(String host) => Account(
  key: AccountKey(type: BackendType.mastodon, host: host, username: 'pooza'),
  adapter: _Adapter(),
  user: User(id: host, username: 'pooza'),
  userSecret: const UserSecret(accessToken: 'token'),
);

class _TestAccountNotifier extends AccountManagerNotifier {
  _TestAccountNotifier(this._accounts);

  final List<Account> _accounts;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: _accounts, current: _accounts.first);
}

void main() {
  final bshock = _account('bshock.example');
  final delmulin = _account('delmulin.example');
  final third = _account('third.example');

  /// [column] を渡すと、デッキのカラムと同じ形で見ているアカウントを上書きする。
  Future<(List<String>, bool)> candidates(
    WidgetTester tester,
    List<Account> accounts, {
    Account? column,
  }) async {
    late List<String> hosts;
    late bool hasOthers;
    Widget probe = Consumer(
      builder: (context, ref, _) {
        hosts = [for (final a in crossAccountBoostCandidates(ref)) a.key.host];
        hasOthers = hasOtherAccounts(ref);
        return const SizedBox.shrink();
      },
    );
    if (column != null) {
      probe = ProviderScope(
        overrides: [currentAccountProvider.overrideWithValue(column)],
        child: probe,
      );
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountManagerProvider.overrideWith(
            () => _TestAccountNotifier(accounts),
          ),
        ],
        child: probe,
      ),
    );
    return (hosts, hasOthers);
  }

  testWidgets('デッキの外では、現在のアカウントを除く（今までと同じ）', (tester) async {
    final (hosts, hasOthers) = await candidates(tester, [
      bshock,
      delmulin,
      third,
    ]);

    expect(hosts, ['delmulin.example', 'third.example']);
    expect(hasOthers, isTrue);
  });

  testWidgets('⚠⚠ カラムの中では、カラムのアカウントを除く（現在のアカウントは候補に出る）', (tester) async {
    // 報告の形: 現在のアカウントは美食丼。デルムリン丼のカラムで開く。
    final (hosts, hasOthers) = await candidates(tester, [
      bshock,
      delmulin,
      third,
    ], column: delmulin);

    expect(hosts, ['bshock.example', 'third.example']);
    expect(hasOthers, isTrue);
  });

  testWidgets('アカウントが 1 つなら候補は無く、メニューも出さない', (tester) async {
    final (hosts, hasOthers) = await candidates(tester, [bshock]);

    expect(hosts, isEmpty);
    expect(hasOthers, isFalse);
  });
}

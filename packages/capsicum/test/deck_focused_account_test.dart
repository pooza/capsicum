import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/model/deck_column.dart';
import 'package:capsicum/src/ui/util/deck_navigation.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1286 / #1367: デッキのドロワーとメニューバーが、開く前に切り替える先の
/// アカウント（[deckFocusedOtherAccount]）。2 つで食い違わせないため 1 か所にした。
class _Adapter extends Mock implements DecentralizedBackendAdapter {}

AccountKey _key(String username) => AccountKey(
  type: BackendType.misskey,
  host: 'misskey.example',
  username: username,
);

Account _account(String username) => Account(
  key: _key(username),
  adapter: _Adapter(),
  user: User(id: username, username: username),
  userSecret: const UserSecret(accessToken: 'token'),
);

void main() {
  final me = _account('me');
  final other = _account('other');
  final columns = [
    DeckColumn(id: 'mine', account: me.key, tab: const NotificationsTab()),
    DeckColumn(id: 'theirs', account: other.key, tab: const NotificationsTab()),
    DeckColumn(id: 'all', account: other.key, tab: const AllNotificationsTab()),
    DeckColumn(
      id: 'gone',
      account: _key('loggedout'),
      tab: const NotificationsTab(),
    ),
  ];

  Account? resolve(String? focused) => deckFocusedOtherAccount(
    columns: columns,
    focusedColumnId: focused,
    current: me.key,
    accounts: [me, other],
  );

  test('別アカウントのカラムなら、そのアカウント', () {
    expect(resolve('theirs')?.key, other.key);
  });

  test('現在のアカウントのカラムなら切り替えない', () {
    expect(resolve('mine'), isNull);
  });

  test('アカウントをまたぐカラム（すべての通知）では切り替えない', () {
    expect(resolve('all'), isNull);
  });

  test('フォーカスが無い・カラムが無いときは切り替えない', () {
    expect(resolve(null), isNull);
    expect(resolve('missing'), isNull);
  });

  test('接続済みに無いアカウント（ログアウト直後など）へは切り替えない', () {
    expect(resolve('gone'), isNull);
  });
}

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/is_cat_provider.dart';
import '../../util/user_acct.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/cursor_paged_list_view.dart';
import '../widget/emoji_text.dart';
import '../widget/user_avatar.dart';

enum UserListType { followers, following, favouritedBy, rebloggedBy }

typedef UserListFetcher =
    Future<({List<User> users, String? nextCursor})> Function(String? cursor);

class UserListScreen extends StatelessWidget {
  final String title;
  final UserListFetcher fetcher;

  const UserListScreen({super.key, required this.title, required this.fetcher});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: UserListView(fetcher: fetcher),
  );
}

/// ユーザー一覧の中身だけを持つ widget (#1039)。
///
/// ⚠ **Scaffold を含めない。**タブの中に並べる用途（ブロック / ミュートの
/// 2 タブ）が出たため、[UserListScreen] から切り出した。画面として使うときは
/// [UserListScreen] が Scaffold と AppBar を被せる。
///
/// ⚠ **ページングの骨格は [CursorPagedListView] が持つ (#1083-A)。**ここが足すのは
/// isCat の補完（[CursorPagedListView.enrich]）と行の描き方だけ。**世代カウンタ・
/// 「0 件」と「引けない」の描き分け・プリフェッチ閾値は向こうの正本を見ること。**
class UserListView extends ConsumerWidget {
  final UserListFetcher fetcher;

  /// 一覧が空のときの文言。既定は「ユーザーはいません」。
  final String emptyMessage;

  /// 各行の末尾に置く widget（解除ボタン等）。省略時は何も置かない。
  final Widget Function(User user)? trailingBuilder;

  const UserListView({
    super.key,
    required this.fetcher,
    this.emptyMessage = 'ユーザーはいません',
    this.trailingBuilder,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return BottomSafeArea(
      child: CursorPagedListView<User>(
        debugLabel: 'UserListScreen',
        // ⚠ **ページサイズはこの View が決めない。**`fetcher` を渡す側が
        // `limit` ごと閉じ込めている。
        fetcher: (cursor) async {
          final page = await fetcher(cursor);
          return (items: page.users, nextCursor: page.nextCursor);
        },
        // ⚠ **`ref` は渡ってきたものを使う (#1064)。**ここで外側の `ref` を
        // 閉じ込めると、await をまたいだあとに dispose 済みを読む形になる。
        enrich: (ref, users) =>
            ref.read(isCatEnricherProvider).enrichUsers(users),
        emptyMessage: emptyMessage,
        itemBuilder: (context, user) => ListTile(
          onTap: () => context.push('/profile', extra: user),
          leading: UserAvatar(user: user, size: 40),
          title: EmojiText(
            user.displayName ?? user.username,
            emojis: user.emojis,
            fallbackHost: user.host,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '@${userAcct(user)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: trailingBuilder?.call(user),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../model/account.dart';
import '../../provider/account_manager_provider.dart';
import '../../util/now_playing_formatter.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/server_badge.dart';
import '../widget/user_avatar.dart';

/// 共有を受け取った先の route。アカウントが 2 つ以上なら選ばせる (#1348)。
String shareDestination(int accountCount) =>
    accountCount >= 2 ? '/share/account' : '/compose';

/// 共有されたナウプレを投稿するアカウントを選ぶ (#1348)。
///
/// ⚠⚠ **投稿フォームの中で切り替えない。**本文の整形（モロヘイヤ）・下書きの
/// スロット・公開範囲の既定は、開いたときのアカウントを前提にしている。
///
/// ⚠ iOS の共有拡張は本体を開けないので、共有してから開くまでに間が空く。何を
/// 共有したのかを忘れていることがあるので、見出しと共有の中身を一覧の上に出す。
class ShareAccountScreen extends ConsumerStatefulWidget {
  const ShareAccountScreen({super.key, required this.sharedText});

  final String sharedText;

  @override
  ConsumerState<ShareAccountScreen> createState() => _ShareAccountScreenState();
}

class _ShareAccountScreenState extends ConsumerState<ShareAccountScreen> {
  /// 共有の中身を読める形にしたもの。引けなければ共有のまま出す。
  String? _resolved;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  /// 共有で運べるのは URL かテキストだけなので、曲名はモロヘイヤで引く。
  ///
  /// ⚠ どのアカウントが選ばれるかはまだ分からないので、使えるものを借りる。
  /// 投稿フォームの整形は、選んだアカウントのモロヘイヤでやり直す。
  Future<void> _resolve() async {
    final text = widget.sharedText.trim();
    if (!isSingleNowPlayingUrl(text)) return;
    final accounts = ref.read(accountManagerProvider).accounts;
    final account = accounts
        .where((a) => a.mulukhiya?.nowplayingUrlResolverEnabled ?? false)
        .firstOrNull;
    if (account == null) return;
    try {
      final info = await account.mulukhiya!.resolveNowPlayingByUrl(
        accessToken: account.userSecret.accessToken,
        url: text,
      );
      final title = info?.title;
      if (title == null || title.isEmpty || !mounted) return;
      final artist = info?.artist;
      setState(() {
        _resolved = artist == null || artist.isEmpty
            ? title
            : '$title / $artist';
      });
    } catch (_) {
      // 表示の補助なので、共有のまま出す。
    }
  }

  void _select(Account account) {
    ref
        .read(accountManagerProvider.notifier)
        .switchAccount(account, clearUnread: false);
    context.pushReplacement(
      '/compose',
      extra: <String, dynamic>{'sharedText': widget.sharedText},
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(accountManagerProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('ナウプレを投稿するアカウントを選ぶ')),
      body: BottomSafeArea(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.music_note),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _resolved ?? widget.sharedText.trim(),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            for (final account in state.accounts)
              ListTile(
                leading: UserAvatar(user: account.user, size: 40),
                title: Text(_nameOf(account.user)),
                subtitle: Row(
                  children: [
                    ServerFavicon(host: account.key.host),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '@${account.key.username}@${account.key.host}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                trailing: account.key == state.current?.key
                    ? Icon(Icons.check, color: theme.colorScheme.primary)
                    : null,
                onTap: () => _select(account),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '選ばずに閉じると、共有は取り消されます。',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _nameOf(User user) {
    final name = user.displayName;
    return name == null || name.isEmpty ? user.username : name;
  }
}

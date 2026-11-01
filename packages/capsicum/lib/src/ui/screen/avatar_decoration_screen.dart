import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../../util/misskey_api_error.dart';
import '../../util/oauth_scope_error.dart';
import '../util/op_error.dart';
import '../widget/bottom_safe_area.dart';
import '../widget/retry_error_view.dart';
import '../widget/user_avatar.dart';

/// サーバーのデコレーション一覧。
final avatarDecorationOptionsProvider =
    FutureProvider.autoDispose<List<AvatarDecorationOption>>((ref) async {
      final adapter = ref.watch(currentAdapterProvider);
      if (adapter is! AvatarDecorationSupport) return const [];
      return (adapter as AvatarDecorationSupport).getAvatarDecorationOptions();
    }, dependencies: [currentAdapterProvider]);

/// アイコンデコレーションの付け外し (#1349)。
///
/// 季節のイベントなどで気軽に付け替えられるよう、押したらその場で保存する。
/// ⚠ 位置・角度・反転の調整は置かない（Web で調整した値は崩さない）。
class AvatarDecorationScreen extends ConsumerStatefulWidget {
  const AvatarDecorationScreen({super.key});

  @override
  ConsumerState<AvatarDecorationScreen> createState() =>
      _AvatarDecorationScreenState();
}

class _AvatarDecorationScreenState
    extends ConsumerState<AvatarDecorationScreen> {
  /// 保存中のデコレーション。連打で順番が入れ替わらないよう、1 つずつ送る。
  String? _savingId;

  /// 開いた画面のアカウントへ書き戻す。⚠ `updateCurrentUser` は現在のアカウントを
  /// 書き換えるので、別アカウントのカラムから来たときに使えない。
  User? _localUser;

  Future<void> _toggle(AvatarDecorationOption option, bool attached) async {
    if (_savingId != null) return;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! AvatarDecorationSupport) return;
    final support = adapter as AvatarDecorationSupport;
    final messenger = ScaffoldMessenger.of(context);
    final account = ref.read(currentAccountProvider);
    final accounts = ref.read(accountManagerProvider.notifier);
    setState(() => _savingId = option.id);
    try {
      final user = attached
          ? await support.detachAvatarDecoration(option.id)
          : await support.attachAvatarDecoration(option.id);
      if (account != null) accounts.updateUserOf(account.key, user);
      if (mounted) setState(() => _localUser = user);
    } on AvatarDecorationRejected {
      messenger.showSnackBar(
        SnackBar(content: Text('「${option.name}」はこのアカウントでは使えません')),
      );
    } on AvatarDecorationLimitReached catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('付けられるのは ${e.limit} 個までです。先にどれかを外してください')),
      );
    } catch (e, st) {
      if (isOAuthScopeError(e)) {
        messenger.showSnackBar(
          const SnackBar(content: Text('権限が不足しています。再ログインしてください')),
        );
      } else if (misskeyApiErrorCode(e) == 'RESTRICTED_BY_ROLE') {
        messenger.showSnackBar(
          const SnackBar(content: Text('付けられる数を超えています。先にどれかを外してください')),
        );
      } else {
        reportOpFailure(
          tagKey: 'avatar_decoration.op',
          operation: attached ? 'detach' : 'attach',
          error: e,
          stackTrace: st,
          account: account,
        );
        messenger.showSnackBar(
          SnackBar(content: Text('保存できませんでした\n${summarizeOpError(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = ref.watch(avatarDecorationOptionsProvider);
    final user = _localUser ?? ref.watch(currentAccountProvider)?.user;
    final attachedIds = {
      for (final d in user?.avatarDecorations ?? const <AvatarDecoration>[])
        d.id,
    };
    return Scaffold(
      appBar: AppBar(title: const Text('アイコンデコレーション')),
      body: BottomSafeArea(
        child: Column(
          children: [
            if (user != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: UserAvatar(user: user, size: 96),
              ),
            Expanded(
              child: options.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => RetryErrorView(
                  message: '読み込みに失敗しました\n${summarizeOpError(e)}',
                  isRetrying: options.isLoading,
                  onRetry: () =>
                      ref.invalidate(avatarDecorationOptionsProvider),
                ),
                data: (list) {
                  if (list.isEmpty) {
                    return const Center(child: Text('デコレーションはありません'));
                  }
                  return ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, index) {
                      final option = list[index];
                      final attached = attachedIds.contains(option.id);
                      final description = option.description;
                      return ListTile(
                        leading: Image.network(
                          option.url,
                          width: 48,
                          height: 48,
                          errorBuilder: (_, _, _) =>
                              const Icon(Icons.broken_image, size: 48),
                        ),
                        title: Text(option.name),
                        subtitle: description == null || description.isEmpty
                            ? null
                            : Text(
                                description,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                        trailing: _savingId == option.id
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                attached
                                    ? Icons.check_circle
                                    : Icons.circle_outlined,
                                color: attached
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                        selected: attached,
                        onTap: () => _toggle(option, attached),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

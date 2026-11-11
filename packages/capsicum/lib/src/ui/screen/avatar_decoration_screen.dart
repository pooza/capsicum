import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/list_fetch.dart';
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
      return fetchListReportingFailure(
        ref,
        tagKey: 'avatar_decoration.list',
        operation: 'options',
        fetch: () =>
            (adapter as AvatarDecorationSupport).getAvatarDecorationOptions(),
      );
    }, dependencies: [currentAdapterProvider, currentAccountProvider]);

/// 付けられる数の上限 (#1359)。⚠ 読めなくても画面は使えるので、失敗は null
/// （残りの数を出さないだけ）。
final avatarDecorationLimitProvider = FutureProvider.autoDispose<int?>((
  ref,
) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter is! AvatarDecorationSupport) return null;
  try {
    return await (adapter as AvatarDecorationSupport)
        .getAvatarDecorationLimit();
  } catch (_) {
    return null;
  }
}, dependencies: [currentAdapterProvider, currentAccountProvider]);

/// 一覧の上に出す、あといくつ付けられるか (#1359)。上限が読めなければ null。
///
/// ⚠ 上限が 1 のサーバーでは、付けると入れ替わる（#1349）。「あと 0 個」と
/// 出すと付けられないように読めるので、入れ替わることを言う。
String? avatarDecorationRemainingLabel({
  required int attached,
  required int? limit,
}) {
  if (limit == null) return null;
  if (limit <= 0) return 'このアカウントではデコレーションを付けられません';
  if (limit == 1) return '付けられるのは 1 個です。ほかを選ぶと入れ替わります';
  final remaining = (limit - attached).clamp(0, limit);
  return 'あと $remaining 個付けられます（$attached / $limit）';
}

/// アイコンデコレーションの付け外しと調整 (#1349 / #1359)。
///
/// 季節のイベントなどで気軽に付け替えられるよう、押したらその場で保存する。
/// 位置・角度・反転は、付けているものの「調整」から変える（スライダー・
/// 2026-11-10 pooza）。
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

  /// 開いた画面のアカウントへ書き戻す。⚠ 「現在のアカウント」へ書き戻す形
  /// （#1361 で消した）は、別アカウントのカラムから来たときに別の人を書き換える。
  User? _localUser;

  /// [save] を 1 件ずつ走らせ、応答を手元とアカウントへ反映する。
  Future<void> _run(
    AvatarDecorationOption option,
    String operation,
    Future<User> Function(AvatarDecorationSupport support) save,
  ) async {
    if (_savingId != null) return;
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! AvatarDecorationSupport) return;
    final support = adapter as AvatarDecorationSupport;
    final messenger = ScaffoldMessenger.of(context);
    final account = ref.read(currentAccountProvider);
    final accounts = ref.read(accountManagerProvider.notifier);
    setState(() => _savingId = option.id);
    try {
      final user = await save(support);
      if (account != null) accounts.updateUserOf(account.key, user);
      if (mounted) setState(() => _localUser = user);
      if (operation == 'adjust' &&
          !user.avatarDecorations.any((d) => d.id == option.id)) {
        // サーバー側（Web など）で既に外れていた。
        messenger.showSnackBar(
          SnackBar(content: Text('「${option.name}」はもう外れていました')),
        );
      }
    } on AvatarDecorationRejected catch (e) {
      // ⚠ サーバーの今の状態で揃える（入れ替えで外したものは付け直してある）。
      if (account != null) accounts.updateUserOf(account.key, e.user);
      if (mounted) setState(() => _localUser = e.user);
      messenger.showSnackBar(
        SnackBar(content: Text('「${option.name}」はこのアカウントでは使えません')),
      );
    } on AvatarDecorationLimitReached catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.limit == 0
                ? 'このアカウントではデコレーションを付けられません'
                : '付けられるのは ${e.limit} 個までです。先にどれかを外してください',
          ),
        ),
      );
    } catch (e, st) {
      // ⚠ ロールで数を絞られたとき（`RESTRICTED_BY_ROLE`）は、アダプターが
      // AvatarDecorationLimitReached に写すので、ここには来ない（上の on 節・#1361）。
      if (isOAuthScopeError(e)) {
        messenger.showSnackBar(
          const SnackBar(content: Text(oauthScopeErrorMessage)),
        );
      } else if (misskeyApiErrorCode(e) == 'RATE_LIMIT_EXCEEDED') {
        // ⚠ i/update は 1 時間に 20 回まで。付け替えを続けると当たる既知の条件。
        messenger.showSnackBar(
          const SnackBar(content: Text('短い間に保存しすぎました。しばらく待ってから試してください')),
        );
      } else {
        reportOpFailure(
          tagKey: 'avatar_decoration.op',
          operation: operation,
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

  Future<void> _toggle(AvatarDecorationOption option, bool attached) => _run(
    option,
    attached ? 'detach' : 'attach',
    (support) => attached
        ? support.detachAvatarDecoration(option.id)
        : support.attachAvatarDecoration(option.id),
  );

  /// 位置・角度・反転を調整する (#1359)。
  Future<void> _adjust(
    AvatarDecorationOption option,
    User user,
    AvatarDecoration decoration,
  ) async {
    final result = await showModalBottomSheet<AvatarDecoration>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => AvatarDecorationAdjustSheet(
        user: user,
        name: option.name,
        target: decoration,
      ),
    );
    if (result == null || !mounted) return;
    await _run(
      option,
      'adjust',
      (support) => support.adjustAvatarDecoration(
        option.id,
        angle: result.angle,
        flipH: result.flipH,
        offsetX: result.offsetX,
        offsetY: result.offsetY,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final options = ref.watch(avatarDecorationOptionsProvider);
    final limit = ref.watch(avatarDecorationLimitProvider).value;
    final user = _localUser ?? ref.watch(currentAccountProvider)?.user;
    final attachedById = {
      for (final d in user?.avatarDecorations ?? const <AvatarDecoration>[])
        d.id: d,
    };
    final remaining = avatarDecorationRemainingLabel(
      attached: attachedById.length,
      limit: limit,
    );
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
            if (remaining != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  remaining,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
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
                      final decoration = attachedById[option.id];
                      final attached = decoration != null;
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
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (attached && user != null)
                                    IconButton(
                                      icon: const Icon(Icons.tune),
                                      tooltip: '位置と角度を調整',
                                      onPressed: _savingId != null
                                          ? null
                                          : () => _adjust(
                                              option,
                                              user,
                                              decoration,
                                            ),
                                    ),
                                  Icon(
                                    attached
                                        ? Icons.check_circle
                                        : Icons.circle_outlined,
                                    color: attached
                                        ? Theme.of(context).colorScheme.primary
                                        : null,
                                  ),
                                ],
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

/// デコレーション 1 つの位置・角度・反転を調整するシート (#1359)。決めたら
/// 新しい値を返し、やめたら null。
///
/// ⚠ プレビューは表示側と同じ [UserAvatar] で描く（ずれた見た目で保存させない）。
/// ほかのデコレーションも今の値のまま一緒に描く。
class AvatarDecorationAdjustSheet extends StatefulWidget {
  const AvatarDecorationAdjustSheet({
    super.key,
    required this.user,
    required this.name,
    required this.target,
  });

  final User user;
  final String name;
  final AvatarDecoration target;

  @override
  State<AvatarDecorationAdjustSheet> createState() =>
      _AvatarDecorationAdjustSheetState();
}

class _AvatarDecorationAdjustSheetState
    extends State<AvatarDecorationAdjustSheet> {
  late double _angle = widget.target.angle.clamp(-0.5, 0.5);
  late bool _flipH = widget.target.flipH;
  late double _offsetX = widget.target.offsetX.clamp(-0.25, 0.25);
  late double _offsetY = widget.target.offsetY.clamp(-0.25, 0.25);

  AvatarDecoration get _edited => AvatarDecoration(
    id: widget.target.id,
    url: widget.target.url,
    angle: _angle,
    flipH: _flipH,
    offsetX: _offsetX,
    offsetY: _offsetY,
  );

  Widget _slider({
    required String label,
    required double value,
    required double limit,
    required ValueChanged<double> onChanged,
  }) => Row(
    children: [
      SizedBox(width: 40, child: Text(label)),
      Expanded(
        child: Slider(
          value: value,
          min: -limit,
          max: limit,
          divisions: 100,
          label: value.toStringAsFixed(2),
          onChanged: (v) => setState(() => onChanged(v)),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final decorations = [
      for (final d in widget.user.avatarDecorations)
        d.id == widget.target.id ? _edited : d,
    ];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '「${widget.name}」の位置と角度',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: UserAvatar(
                  user: widget.user,
                  size: 96,
                  decorations: decorations,
                ),
              ),
            ),
            _slider(
              label: '角度',
              value: _angle,
              limit: 0.5,
              onChanged: (v) => _angle = v,
            ),
            _slider(
              label: '横',
              value: _offsetX,
              limit: 0.25,
              onChanged: (v) => _offsetX = v,
            ),
            _slider(
              label: '縦',
              value: _offsetY,
              limit: 0.25,
              onChanged: (v) => _offsetY = v,
            ),
            SwitchListTile(
              title: const Text('左右反転'),
              value: _flipH,
              contentPadding: EdgeInsets.zero,
              onChanged: (v) => setState(() => _flipH = v),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    _angle = 0;
                    _flipH = false;
                    _offsetX = 0;
                    _offsetY = 0;
                  }),
                  child: const Text('リセット'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('キャンセル'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, _edited),
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

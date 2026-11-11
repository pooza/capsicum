import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../model/account.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/clip_provider.dart';
import '../../service/sentry_op_failure.dart';
import '../../util/oauth_scope_error.dart';
import '../util/op_error.dart';
import '../util/provider_scope_carrier.dart';
import 'clip_actions_sheet.dart';

/// 投稿の「クリップに追加」(#1050)。
///
/// 自分のクリップを並べ、押すと入れる / 外す。末尾の「新しいクリップ」で作って
/// そのまま入れる。
///
/// ⚠⚠ **入っているかの印は「分かる分だけ」**（2026-11-10 pooza）。Misskey の
/// `notes/clips` は公開のクリップしか返さないので、印を付けられるのは
/// 自分の公開クリップと、このシートで入れた / 外したものだけ。**印が無いことは
/// 「入っていない」を意味しない。**印の無いクリップを押して「もう入っている」
/// （[AlreadyClipped]）が返ったら、Web と同じく外すかを尋ねる。
Future<void> showAddToClipSheet(
  BuildContext context,
  WidgetRef ref,
  Post post,
) async {
  final adapter = ref.read(currentAdapterProvider);
  if (adapter is! ClipSupport || adapter is! ClipManagementSupport) return;
  // ⚠ 開いた時点で控える（#1064 の書き方。シートの中の失敗の記録に添える）。
  final account = ref.read(currentAccountProvider);
  // ⚠⚠ シートは別のルートに乗るので、中の `context` はルートのスコープになる。
  // 開いた側（デッキのカラム）のスコープで包まないと、「新しいクリップ」の
  // 画面が**ルートで選ばれている別のアカウント**にクリップを作る。
  final container = ProviderScope.containerOf(context, listen: false);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => carryProviderScope(
      container,
      ClipAddSheet(
        post: post,
        clips: adapter as ClipSupport,
        manage: adapter as ClipManagementSupport,
        account: account,
      ),
    ),
  );
  // 新しいクリップを作ったかもしれないので、一覧を取り直させる。
  if (context.mounted) {
    ProviderScope.containerOf(context, listen: false).invalidate(clipsProvider);
  }
}

class ClipAddSheet extends StatefulWidget {
  const ClipAddSheet({
    super.key,
    required this.post,
    required this.clips,
    required this.manage,
    required this.account,
  });

  final Post post;
  final ClipSupport clips;
  final ClipManagementSupport manage;

  /// 開いたときのアカウント。失敗の記録に添える。
  final Account? account;

  @override
  State<ClipAddSheet> createState() => _ClipAddSheetState();
}

class _ClipAddSheetState extends State<ClipAddSheet> {
  List<NoteClip>? _list;
  Object? _loadError;

  /// 入っていると分かっているクリップの id。
  final _contains = <String>{};

  /// 送っている最中のクリップの id。
  String? _busyId;

  /// シートの中に出す結果の 1 行。
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // ⚠ 通信中にシートを閉じたあとでも呼ばれる（`_add` / `_remove` の後始末）。
    if (!mounted) return;
    setState(() => _loadError = null);
    try {
      final clips = await widget.clips.getClips();
      // ⚠ 分からなくてもシートは使える（印が出ないだけ）。
      Set<String> known;
      try {
        known = await widget.manage.getPublicClipIdsContaining(widget.post.id);
      } catch (_) {
        known = const {};
      }
      if (!mounted) return;
      final mine = {for (final c in clips) c.id};
      setState(() {
        _list = clips;
        _contains
          ..clear()
          ..addAll(known.where(mine.contains));
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  /// ⚠ 通信中にシートを払って閉じたあとで呼ばれることがあるので、`mounted` を
  /// ここで見る（呼ぶ側の各 `on` 節では見ていない）。
  void _say(String message) {
    if (!mounted) return;
    setState(() => _message = message);
  }

  Future<void> _toggle(NoteClip clip) async {
    if (_busyId != null) return;
    final wasContained = _contains.contains(clip.id);
    var alreadyClipped = false;
    setState(() {
      _busyId = clip.id;
      _message = null;
    });
    try {
      if (wasContained) {
        await _remove(clip);
      } else {
        alreadyClipped = await _add(clip);
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
    // ⚠ 尋ねるのは進行中の表示を消してから（尋ねている間に処理中に見せない）。
    if (alreadyClipped && mounted && await _confirmRemove(clip) && mounted) {
      setState(() => _busyId = clip.id);
      try {
        await _remove(clip);
      } finally {
        if (mounted) setState(() => _busyId = null);
      }
    }
  }

  /// 入れる。もう入っていたら印を付けて `true` を返す（呼ぶ側が外すかを尋ねる）。
  Future<bool> _add(NoteClip clip) async {
    try {
      await widget.manage.addNoteToClip(clip.id, widget.post.id);
      if (!mounted) return false;
      setState(() => _contains.add(clip.id));
      _say('「${clip.name}」に入れました');
    } on AlreadyClipped {
      // もう入っていた。印を付け、外すかを尋ねる（Web と同じ）。
      if (mounted) setState(() => _contains.add(clip.id));
      return true;
    } on ClipNoteLimitReached {
      _say('「${clip.name}」には、これ以上入れられません');
    } on ClipNotFound {
      _say('「${clip.name}」は見つかりませんでした（削除された可能性があります）');
      await _load();
    } catch (e, st) {
      _fail(e, st, 'add');
    }
    return false;
  }

  Future<bool> _confirmRemove(NoteClip clip) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          content: Text('この投稿は「${clip.name}」に入っています。外しますか？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('そのまま'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('外す'),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _remove(NoteClip clip) async {
    try {
      await widget.manage.removeNoteFromClip(clip.id, widget.post.id);
      if (!mounted) return;
      setState(() => _contains.remove(clip.id));
      _say('「${clip.name}」から外しました');
    } on ClipNotFound {
      _say('「${clip.name}」は見つかりませんでした（削除された可能性があります）');
      await _load();
    } catch (e, st) {
      _fail(e, st, 'remove');
    }
  }

  void _fail(Object e, StackTrace st, String operation) {
    // ⚠ 権限の足りない古いトークンは送らない（再ログインで直る・#1361）。
    final scope = isOAuthScopeError(e);
    if (!scope) {
      reportOpFailure(
        tagKey: 'clip.op',
        operation: operation,
        error: e,
        stackTrace: st,
        account: widget.account,
      );
    }
    if (!mounted) return;
    _say(scope ? oauthScopeErrorMessage : '保存できませんでした\n${summarizeOpError(e)}');
  }

  Future<void> _createAndAdd() async {
    if (_busyId != null) return;
    // ⚠⚠ 開いた側のスコープを運ぶ。運ばないと、デッキで別アカウントのカラムから
    // 開いたとき、ルートで選ばれているアカウントにクリップを作る。
    final created = await context.push<Object?>(
      '/clips/edit',
      extra: extraWithProviderScope(context),
    );
    if (!mounted || created is! NoteClip) return;
    setState(() => _list = [...?_list, created]);
    await _toggle(created);
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('クリップに追加', style: theme.textTheme.titleMedium),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(_message!, style: theme.textTheme.bodySmall),
              ),
            if (_loadError != null)
              ListTile(
                title: Text(
                  isOAuthScopeError(_loadError!)
                      ? oauthScopeErrorMessage
                      : 'クリップの取得に失敗しました',
                ),
                trailing: TextButton(
                  onPressed: _load,
                  child: const Text('再試行'),
                ),
              )
            else if (list == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final clip in list)
                      ListTile(
                        leading: Icon(clipVisibilityIcon(clip)),
                        title: Text(
                          clip.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: _busyId == clip.id
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                _contains.contains(clip.id)
                                    ? Icons.check_circle
                                    : Icons.circle_outlined,
                                color: _contains.contains(clip.id)
                                    ? theme.colorScheme.primary
                                    : null,
                              ),
                        onTap: () => _toggle(clip),
                      ),
                    ListTile(
                      leading: const Icon(Icons.add),
                      title: const Text('新しいクリップ'),
                      onTap: _createAndAdd,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

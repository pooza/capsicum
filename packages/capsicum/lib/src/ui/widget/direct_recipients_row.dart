import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';

import '../../util/user_acct.dart';
import 'user_avatar.dart';

/// 宛先 1 人ぶん (#1165)。
///
/// [user] は id からサーバーへ問い合わせて取る。**取れるまで・取れなかった回は
/// null**（そのあいだも、外すことはできる）。
class DirectRecipient {
  const DirectRecipient({
    required this.id,
    this.user,
    this.loading = false,
    this.locked = false,
  });

  final String id;
  final User? user;

  /// 問い合わせ中。
  final bool loading;

  /// 外せない（返信先の投稿者。サーバーが必ず宛先に足す）。
  final bool locked;
}

/// 宛先の行そのもの。テストから探すための目印。
const directRecipientsRowKey = Key('direct_recipients_row');

/// 宛先を足すボタン。
const directRecipientsAddKey = Key('direct_recipients_add');

/// 指名（Misskey の `specified`）の宛先を並べる行 (#1165)。
///
/// ⚠ **1 行に収め、多いときは横にスクロールする。**投稿画面は狭幅（375px）が
/// 前提で、宛先の数だけ行を増やすと本文の面積を削る。
///
/// ⚠ **本文のメンションとは連動しない。**届く相手はここに並んでいる人で、本文から
/// `@` を消しても変わらない（Misskey の Web UI と同じ）。だから**全員が見えていて、
/// 外せる**ことがこの行の存在理由になる。
class DirectRecipientsRow extends StatelessWidget {
  const DirectRecipientsRow({
    super.key,
    required this.recipients,
    required this.onRemove,
    required this.onAdd,
    this.enabled = true,
  });

  final List<DirectRecipient> recipients;
  final void Function(String id) onRemove;
  final VoidCallback onAdd;

  /// 送信中などは操作を止める。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: directRecipientsRowKey,
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Text('宛先', style: theme.textTheme.bodySmall),
          const SizedBox(width: 8),
          Expanded(
            child: recipients.isEmpty
                ? Text(
                    'まだ誰も入っていません',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  )
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final recipient in recipients)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: _chip(context, recipient),
                          ),
                      ],
                    ),
                  ),
          ),
          IconButton(
            key: directRecipientsAddKey,
            icon: const Icon(Icons.person_add_alt),
            tooltip: '宛先を足す',
            visualDensity: VisualDensity.compact,
            onPressed: enabled ? onAdd : null,
          ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, DirectRecipient recipient) {
    final user = recipient.user;
    final label = user != null
        ? '@${userAcct(user)}'
        : recipient.loading
        ? '読み込み中…'
        // ⚠ 名前を取れなかった人も、消さずに出す。届くことは変わらないので、
        // 見えなくするほうが害が大きい。外すことはできる。
        : '不明な利用者';
    final chip = InputChip(
      avatar: user != null
          ? UserAvatar(user: user, size: 24, compact: true)
          : recipient.loading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.person_outline, size: 18),
      label: Text(label),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      // ⚠ 外せない宛先には × を出さない（押せるのに外れない、にしない）。
      onDeleted: recipient.locked || !enabled
          ? null
          : () => onRemove(recipient.id),
      deleteButtonTooltipMessage: '宛先から外す',
    );
    if (!recipient.locked) return chip;
    return Tooltip(message: '返信先の投稿者には必ず届きます', child: chip);
  }
}

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';

/// リストの設定で、変えたぶん。変えなかった項目は null。
typedef ListSettingsChange = ({
  ListRepliesPolicy? repliesPolicy,
  bool? exclusive,
  bool? isPublic,
});

/// 返信の範囲の表示名。
const listRepliesPolicyLabels = {
  ListRepliesPolicy.followed: 'フォローしている人への返信',
  ListRepliesPolicy.list: 'リストのメンバーへの返信',
  ListRepliesPolicy.none: '表示しない',
};

/// リストの設定を見て、変える (#1211)。
///
/// **そのサーバーが持つ項目だけを出す**（[PostList] で null の項目は出さない）。
/// 接続先によって項目が入れ替わる —— Mastodon は返信の範囲とホームからの排他、
/// Misskey は公開。投稿フォームと同じ揃え方。
///
/// 保存すると、**変えた項目だけ**を持つ [ListSettingsChange] を返す。何も変えずに
/// 保存した・閉じたら null。
Future<ListSettingsChange?> showListSettingsDialog(
  BuildContext context,
  PostList list,
) => showDialog<ListSettingsChange>(
  context: context,
  builder: (_) => _ListSettingsDialog(list: list),
);

class _ListSettingsDialog extends StatefulWidget {
  const _ListSettingsDialog({required this.list});

  final PostList list;

  @override
  State<_ListSettingsDialog> createState() => _ListSettingsDialogState();
}

class _ListSettingsDialogState extends State<_ListSettingsDialog> {
  late ListRepliesPolicy? _repliesPolicy = widget.list.repliesPolicy;
  late bool? _exclusive = widget.list.exclusive;
  late bool? _isPublic = widget.list.isPublic;

  ListSettingsChange? get _change {
    final list = widget.list;
    final change = (
      repliesPolicy: _repliesPolicy == list.repliesPolicy
          ? null
          : _repliesPolicy,
      exclusive: _exclusive == list.exclusive ? null : _exclusive,
      isPublic: _isPublic == list.isPublic ? null : _isPublic,
    );
    return change.repliesPolicy == null &&
            change.exclusive == null &&
            change.isPublic == null
        ? null
        : change;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('「${widget.list.title}」の設定'),
      contentPadding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_repliesPolicy != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
                child: Text('このリストに表示する返信', style: theme.textTheme.labelLarge),
              ),
              for (final policy in ListRepliesPolicy.values)
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  leading: Icon(
                    policy == _repliesPolicy
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(listRepliesPolicyLabels[policy]!),
                  onTap: () => setState(() => _repliesPolicy = policy),
                ),
            ],
            if (_exclusive != null)
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                title: const Text('メンバーの投稿をホームに表示しない'),
                // ⚠ リストではなくホームの見え方を変える設定なので、言葉で断る。
                subtitle: const Text('このリストに入れた人の投稿が、ホームのタイムラインに出なくなります'),
                value: _exclusive!,
                onChanged: (v) => setState(() => _exclusive = v),
              ),
            if (_isPublic != null)
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                title: const Text('公開する'),
                subtitle: const Text('ほかの人が、このリストとメンバーを見られるようになります'),
                value: _isPublic!,
                onChanged: (v) => setState(() => _isPublic = v),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_change),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

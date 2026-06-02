import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../provider/preferences_provider.dart';

/// タイムライン上の投稿に対するタッチ操作（タイル上の小ボタン）を
/// アクション別に有効化する設定画面 (#565)。
///
/// 既定は全 OFF。長押しメニューと「…」ボタンは設定に関係なく常に併存する。
class TouchActionSettingsScreen extends ConsumerWidget {
  const TouchActionSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(postTouchActionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('タッチ操作'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              '有効にしたアクションは、タイムラインの各投稿に小さなボタンとして'
              '表示され、長押しせずタップで操作できるようになります。\n'
              '長押しメニュー（および右上の「…」ボタン）は、この設定に関係なく'
              '引き続き利用できます。',
            ),
          ),
          for (final action in PostTouchAction.values)
            SwitchListTile(
              title: Text(_label(action)),
              subtitle: _subtitle(action) != null
                  ? Text(_subtitle(action)!)
                  : null,
              value: enabled.contains(action),
              onChanged: (value) => ref
                  .read(postTouchActionsProvider.notifier)
                  .setEnabled(action, value),
            ),
        ],
      ),
    );
  }

  String _label(PostTouchAction action) {
    return switch (action) {
      PostTouchAction.reply => 'リプライ',
      PostTouchAction.favorite => 'お気に入り',
      PostTouchAction.reaction => 'リアクション',
      PostTouchAction.boost => 'ブースト / リノート',
      PostTouchAction.bookmark => 'ブックマーク',
      PostTouchAction.quote => '引用',
    };
  }

  String? _subtitle(PostTouchAction action) {
    return switch (action) {
      PostTouchAction.favorite => 'Mastodon でのみ表示されます',
      PostTouchAction.reaction => 'Misskey でのみ表示されます',
      PostTouchAction.boost => 'タップ後に公開範囲を選べます',
      _ => null,
    };
  }
}

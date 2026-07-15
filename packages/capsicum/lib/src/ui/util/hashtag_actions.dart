import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

/// ハッシュタグのタップ時に「タグタイムラインを開く / ハッシュタグをコピー」を
/// 選べるドロワーを出す共通導線（#794）。従来はタップ即遷移だった。
///
/// タイムライン・プロフィール・通知・チャット等、`ContentRenderer` の
/// `onHashtagTap` や末尾タグチップから同一挙動で呼ぶ。`tag` は先頭 `#` を除いた
/// タグ名。
void showHashtagActionMenu(BuildContext context, String tag) {
  final messenger = ScaffoldMessenger.of(context);
  showModalBottomSheet(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.tag),
            title: Text('#$tag'),
            dense: true,
          ),
          ListTile(
            leading: const Icon(Icons.dynamic_feed),
            title: const Text('タグタイムラインを開く'),
            onTap: () {
              Navigator.pop(sheetContext);
              context.push('/hashtag/$tag');
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('ハッシュタグをコピー'),
            onTap: () {
              Navigator.pop(sheetContext);
              Clipboard.setData(ClipboardData(text: '#$tag'));
              messenger.showSnackBar(
                const SnackBar(content: Text('ハッシュタグをコピーしました')),
              );
            },
          ),
        ],
      ),
    ),
  );
}

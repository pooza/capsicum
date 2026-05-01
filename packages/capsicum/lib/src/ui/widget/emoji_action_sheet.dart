import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 投稿本文中のカスタム絵文字をタップしたときに表示する BottomSheet (#310)。
/// post_tile / notification_tile など複数箇所から同形で呼ばれるため共通化 (#396)。
///
/// ショートコードのコピーは常時表示。リアクションは [onReact] が渡されたとき
/// (Misskey など ReactionSupport を持つ adapter のみ) 表示する。adapter / post
/// の知識を持たないため、呼び出し側で `_runReactionAction` 等を bind して渡す。
class EmojiActionSheet {
  static void show({
    required BuildContext context,
    required String shortcode,
    required String emojiUrl,
    VoidCallback? onReact,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    final shortcodeText = ':$shortcode:';

    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.content_copy_outlined),
              title: const Text('ショートコードをコピー'),
              subtitle: Text(shortcodeText),
              onTap: () {
                Navigator.pop(sheetContext);
                Clipboard.setData(ClipboardData(text: shortcodeText));
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('ショートコードをコピーしました'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
            if (onReact != null)
              ListTile(
                leading: Image.network(
                  emojiUrl,
                  width: 24,
                  height: 24,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) =>
                      const Icon(Icons.add_reaction_outlined),
                ),
                title: const Text('この絵文字でリアクション'),
                subtitle: Text(shortcodeText),
                onTap: () {
                  Navigator.pop(sheetContext);
                  onReact();
                },
              ),
          ],
        ),
      ),
    );
  }
}

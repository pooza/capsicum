import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/platform_providers.dart';
import '../screen/drive_picker_screen.dart';
import 'insert_picker_sheet.dart';

/// chat の添付ファイルを選ぶ (#613)。ドライブの既存ファイル選択か端末からの
/// アップロードを選ばせ、添付する drive ファイル ([Attachment]) を返す。
/// キャンセル時は null。アップロードの例外は呼び出し側で捕捉する想定。
///
/// Misskey chat は 1 メッセージ 1 ファイルなので、複数選択されても先頭のみ
/// 採用する。
Future<Attachment?> showChatAttachmentPicker(
  BuildContext context,
  WidgetRef ref,
) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: const Text('ドライブから選択'),
            onTap: () => Navigator.pop(sheetContext, 'drive'),
          ),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('アップロード'),
            onTap: () => Navigator.pop(sheetContext, 'upload'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return null;

  if (choice == 'drive') {
    final selected = await Navigator.of(context).push<List<Attachment>>(
      MaterialPageRoute(builder: (_) => const DrivePickerScreen()),
    );
    if (selected == null || selected.isEmpty) return null;
    return selected.first;
  }

  // upload: 端末から選んでドライブにアップロードし、その fileId を使う。
  final files = await ref.read(mediaPickerProvider).pickMultipleMedia();
  if (files.isEmpty) return null;
  final adapter = ref.read(currentAdapterProvider);
  if (adapter == null) return null;
  final file = files.first;
  return adapter.uploadAttachment(
    AttachmentDraft(filePath: file.path, mimeType: file.mimeType),
  );
}

/// chat の入力欄 (#613)。DM ([ChatThreadScreen]) とルーム
/// ([ChatRoomTimelineScreen]) で共用する。テキスト入力 + 添付ボタン + 送信に
/// 加え、添付中のファイルプレビューを表示する。
class ChatComposeRow extends ConsumerWidget {
  final TextEditingController controller;

  /// 送信中。
  final bool sending;

  /// 添付ファイルのアップロード / 選択中。
  final bool uploading;

  /// 添付済みのドライブファイル (未添付なら null)。
  final Attachment? attachedFile;

  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onRemoveAttachment;

  const ChatComposeRow({
    super.key,
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onAttach,
    required this.onRemoveAttachment,
    this.uploading = false,
    this.attachedFile,
  });

  /// カーソル位置（選択範囲があれば置換）にテキストを挿入する。Misskey
  /// メッセージは MFM 解釈なので custom emoji の前後スペースは不要。
  void _insertAtCursor(String value) {
    final text = controller.text;
    final sel = controller.selection;
    final start = sel.baseOffset < 0 ? text.length : sel.baseOffset;
    final end = sel.extentOffset < 0 ? text.length : sel.extentOffset;
    controller.value = TextEditingValue(
      text: text.replaceRange(start, end, value),
      selection: TextSelection.collapsed(offset: start + value.length),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = sending || uploading;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (attachedFile != null)
              _AttachmentPreview(
                file: attachedFile!,
                onRemove: busy ? null : onRemoveAttachment,
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  tooltip: '添付',
                  onPressed: busy ? null : onAttach,
                ),
                // 絵文字 / 劇中ワード等の拡張ピッカー (#686)。compose 本文・簡易
                // バーと同じ共有ランチャをメッセージ入力にも届ける。
                IconButton(
                  icon: const Icon(Icons.emoji_emotions_outlined),
                  tooltip: '絵文字・ワード',
                  onPressed: busy
                      ? null
                      : () => showInsertPickerSheet(
                          context: context,
                          ref: ref,
                          onSelected: _insertAtCursor,
                        ),
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 5,
                    enabled: !busy,
                    decoration: const InputDecoration(
                      hintText: 'メッセージを入力',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                IconButton(
                  icon: busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                  onPressed: busy ? null : onSend,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 添付中ファイルのプレビュー行 (#613)。画像はサムネイル、それ以外は種別
/// アイコン + ファイル名。右端の × で取り消す。
class _AttachmentPreview extends StatelessWidget {
  final Attachment file;
  final VoidCallback? onRemove;

  const _AttachmentPreview({required this.file, this.onRemove});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isImage =
        file.type == AttachmentType.image || file.type == AttachmentType.gifv;
    final thumbUrl = file.previewUrl?.isNotEmpty == true
        ? file.previewUrl!
        : file.url;

    final Widget leading;
    if (isImage && thumbUrl.isNotEmpty) {
      leading = ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.network(
          thumbUrl,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) =>
              const Icon(Icons.broken_image_outlined, size: 24),
        ),
      );
    } else {
      leading = Icon(switch (file.type) {
        AttachmentType.video => Icons.movie_outlined,
        AttachmentType.audio => Icons.audiotrack,
        AttachmentType.gifv => Icons.gif,
        _ => Icons.attach_file,
      }, size: 24);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              file.name?.isNotEmpty == true ? file.name! : '[ファイル]',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            tooltip: '添付を取り消す',
            color: scheme.outline,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

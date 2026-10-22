import 'package:capsicum_core/capsicum_core.dart';

import '../../util/chat_attachment_label.dart';

/// メッセージの一覧に出す 1 行の要約。本文が無ければ添付の種類（`[画像]` など）。
///
/// ⚠ スレッドの一覧とメッセージの検索 (#1188) で共有する（v2.4 リリース前
/// レビュー・検索だけが `（ファイル）` と書いていた）。
String chatMessagePreviewText(ChatMessage message) {
  final text = message.text;
  if (text != null && text.isNotEmpty) return text;
  final file = message.file;
  if (file == null) return '';
  return chatAttachmentLabel(file.type);
}

/// 送り主の短い名前（表示名が無ければユーザー名）。
String chatSenderShortName(ChatMessage message) {
  final name = message.fromUser.displayName;
  if (name != null && name.isNotEmpty) return name;
  return message.fromUser.username;
}

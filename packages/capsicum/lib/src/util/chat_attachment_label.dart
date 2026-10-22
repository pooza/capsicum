import 'package:capsicum_core/capsicum_core.dart';

/// メッセージの添付の、本文の代わりに出す表記（`[画像]` など）(#1304)。
///
/// ⚠⚠ **表記はここ 1 本。**以前はメッセージの一覧と検索（`chat_message_preview`）・
/// プッシュ通知の本文（`push_message_dispatcher`）・DM のスレッドの添付の行
/// （`chat_thread_screen`）がそれぞれ書いていた。
String chatAttachmentLabel(AttachmentType type) => switch (type) {
  AttachmentType.image => '[画像]',
  AttachmentType.video => '[動画]',
  AttachmentType.audio => '[音声]',
  AttachmentType.gifv => '[GIF]',
  AttachmentType.unknown => '[ファイル]',
};

/// MIME 型から添付の種類を出す。プッシュ通知の本文のように、添付を生の JSON
/// （Misskey のドライブのファイル）でしか持っていないところで使う。
///
/// ⚠ `image/gif` は画像（Misskey は GIF を画像として扱う）。
AttachmentType chatAttachmentTypeFromMime(String mime) {
  if (mime.startsWith('image/')) return AttachmentType.image;
  if (mime.startsWith('video/')) return AttachmentType.video;
  if (mime.startsWith('audio/')) return AttachmentType.audio;
  return AttachmentType.unknown;
}

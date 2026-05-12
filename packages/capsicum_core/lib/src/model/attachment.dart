enum AttachmentType { image, video, audio, gifv, unknown }

class Attachment {
  final String id;
  final AttachmentType type;
  final String url;
  final String? previewUrl;
  final String? description;
  final String? name;

  const Attachment({
    required this.id,
    required this.type,
    required this.url,
    this.previewUrl,
    this.description,
    this.name,
  });
}

class AttachmentDraft {
  final String filePath;
  final String? description;
  final String? mimeType;
  final bool sensitive;

  /// Misskey 限定: アップロード先フォルダ ID (#432)。`null` でルートに保存。
  /// Mastodon には folder 概念がないため無視される。
  final String? folderId;

  const AttachmentDraft({
    required this.filePath,
    this.description,
    this.mimeType,
    this.sensitive = false,
    this.folderId,
  });
}

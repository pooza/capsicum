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

  const AttachmentDraft({
    required this.filePath,
    this.description,
    this.mimeType,
    this.sensitive = false,
  });
}

enum AttachmentType { image, video, audio, gifv, unknown }

class Attachment {
  final String id;
  final AttachmentType type;
  final String url;
  final String? previewUrl;
  final String? description;
  final String? name;

  /// 画像が届くまで枠に敷く色（`0xAARRGGBB`）(#1186)。無ければ null。
  ///
  /// ⚠ **単色にした**（2026-10-18 pooza 判断）。blurhash を描くとデコードの依存が
  /// 1 つ増えるため。Misskey は `avgColor`、Mastodon は blurhash の平均色
  /// （[blurhashAverageColor]）から作る。
  final int? placeholderColor;

  const Attachment({
    required this.id,
    required this.type,
    required this.url,
    this.previewUrl,
    this.description,
    this.name,
    this.placeholderColor,
  });
}

const _base83 =
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    r'#$%*+,-.:;=?@[]^_{|}~';

/// blurhash の平均色（DC 成分）を `0xFFRRGGBB` で返す (#1186)。読めなければ null。
///
/// blurhash は 1 文字目が成分の数、2 文字目が AC の最大値、**3〜6 文字目が
/// 平均色（sRGB の 24 bit を base83 の 4 桁）**。平均色だけならデコードは要らない。
int? blurhashAverageColor(String? blurhash) {
  if (blurhash == null || blurhash.length < 6) return null;
  var value = 0;
  for (final char in blurhash.substring(2, 6).split('')) {
    final digit = _base83.indexOf(char);
    if (digit < 0) return null;
    value = value * 83 + digit;
  }
  if (value > 0xFFFFFF) return null;
  return 0xFF000000 | value;
}

/// Misskey の `avgColor`（`rgb(r,g,b)`）を `0xFFRRGGBB` で返す (#1186)。
/// 形が違えば null。
int? cssRgbColor(String? value) {
  if (value == null) return null;
  final match = RegExp(
    r'^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})',
  ).firstMatch(value.trim());
  if (match == null) return null;
  final channels = [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
  if (channels.any((c) => c > 255)) return null;
  return 0xFF000000 | channels[0] << 16 | channels[1] << 8 | channels[2];
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

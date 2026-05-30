import 'package:capsicum_core/capsicum_core.dart';

/// 保存ダイアログに渡すメディアの推奨ファイル名を URL / 添付情報から導出する
/// (#572)。
///
/// 優先順位:
/// 1. [Attachment.name] があればそれ（サーバーが付けた元ファイル名）
/// 2. URL のパス末尾セグメント（クエリ・フラグメントは除去）
/// 3. いずれも無効なら添付種別から `capsicum_media.<ext>` を生成
///
/// 拡張子が欠けている場合は [Attachment.type] から補う。返り値は常に
/// パス区切り文字を含まない安全なファイル名。
String suggestedMediaFileName(Attachment attachment) {
  final fromName = _sanitize(attachment.name);
  if (fromName != null) {
    return _ensureExtension(fromName, attachment.type);
  }

  final fromUrl = _sanitize(_lastPathSegment(attachment.url));
  if (fromUrl != null) {
    return _ensureExtension(fromUrl, attachment.type);
  }

  return 'capsicum_media${_defaultExtension(attachment.type)}';
}

/// URL からクエリ・フラグメントを除いた最終パスセグメントを取り出す。
String? _lastPathSegment(String url) {
  final uri = Uri.tryParse(url);
  if (uri != null && uri.pathSegments.isNotEmpty) {
    return uri.pathSegments.last;
  }
  // URI として解釈できない場合の素朴な fallback。
  final noQuery = url.split('?').first.split('#').first;
  final seg = noQuery.split('/').last;
  return seg.isEmpty ? null : seg;
}

/// パス区切り等を除去し、空なら null を返す。
String? _sanitize(String? raw) {
  if (raw == null) return null;
  final cleaned = raw.replaceAll(RegExp(r'[/\\]'), '').trim();
  return cleaned.isEmpty ? null : cleaned;
}

/// 既に拡張子があればそのまま、無ければ種別由来の拡張子を付ける。
String _ensureExtension(String name, AttachmentType type) {
  final dot = name.lastIndexOf('.');
  // 末尾に近い位置に '.' があり、後続が拡張子らしい長さなら拡張子ありとみなす。
  if (dot > 0 && dot < name.length - 1 && name.length - dot <= 6) {
    return name;
  }
  return '$name${_defaultExtension(type)}';
}

/// 添付種別ごとのデフォルト拡張子。
String _defaultExtension(AttachmentType type) {
  switch (type) {
    case AttachmentType.image:
      return '.png';
    case AttachmentType.video:
    case AttachmentType.gifv:
      return '.mp4';
    case AttachmentType.audio:
      return '.mp3';
    case AttachmentType.unknown:
      return '';
  }
}

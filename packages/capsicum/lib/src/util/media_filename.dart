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

/// 添付の元ファイル名 / URL から拡張子（小文字・先頭ドットなし）を取り出す。
/// 名前にも URL にも拡張子が無ければ null を返す（[suggestedMediaFileName] と
/// 違い、種別由来のデフォルト拡張子は補わない）。
///
/// 「実バイトの形式が分からないならデフォルトに倒さず諦める」用途向け。
/// drag-out (#779) は既定 `.png` に倒すと JPEG/WebP を PNG として advertise して
/// しまうため、この生の拡張子だけで判定する。
String? rawMediaExtension(Attachment attachment) {
  return _extensionOf(_sanitize(attachment.name)) ??
      _extensionOf(_sanitize(_lastPathSegment(attachment.url)));
}

/// 末尾に近い位置に '.' があり、後続が拡張子らしい長さ (1〜5 文字) なら拡張子と
/// みなして小文字で返す。それ以外は null。
String? _extensionOf(String? name) {
  if (name == null) return null;
  final dot = name.lastIndexOf('.');
  if (dot > 0 && dot < name.length - 1 && name.length - dot <= 6) {
    return name.substring(dot + 1).toLowerCase();
  }
  return null;
}

/// 既に拡張子があればそのまま、無ければ種別由来の拡張子を付ける。
String _ensureExtension(String name, AttachmentType type) {
  if (_extensionOf(name) != null) return name;
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

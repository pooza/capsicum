/// ログイン画面に出す、Mastodon 系サーバーの見出し（#658 / #1287）。
///
/// [imageCandidates] は `(url, wide)` の候補を優先順に並べたもの。`wide` は
/// バナー（横長）系なら true・アイコン（正方形）系なら false。絶対化と選択は
/// 画面の側で行う。
class MastodonInstancePreview {
  final String? name;

  /// HTML のまま（画面の側で剥がす）。
  final String description;
  final List<(String?, bool)> imageCandidates;

  const MastodonInstancePreview({
    required this.name,
    required this.description,
    required this.imageCandidates,
  });
}

/// `/api/v2/instance` から作る。
MastodonInstancePreview mastodonInstancePreviewFromV2(
  Map<String, dynamic> data,
) {
  final thumbnail = data['thumbnail'] as Map<String, dynamic>?;
  // thumbnail (バナー) が未設定だと Mastodon はバンドルのデフォルト preview
  // 画像を返すので、それは「指定なし」とみなして PWA アイコン (icon[] の
  // 192px / 最大) にフォールバックする。/api/v2/instance にマスコットは無い (#658)。
  final rawThumb = thumbnail?['url'] as String?;
  return MastodonInstancePreview(
    name: data['title'] as String?,
    description: data['description'] as String? ?? '',
    imageCandidates: [
      (isDefaultMastodonThumbnail(rawThumb) ? null : rawThumb, true),
      (mastodonIcon192(data['icon']), false),
    ],
  );
}

/// `/api/v1/instance` から作る（v2 が無いサーバー・Akkoma などの Pleroma 系・#1287）。
///
/// ⚠ v1 の `thumbnail` は **URL の文字列**（v2 は `{url: ...}`）。`icon[]` は無い。
/// 説明は `description` が空なら `short_description` を使う（Pleroma 系は両方持つ）。
MastodonInstancePreview mastodonInstancePreviewFromV1(
  Map<String, dynamic> data,
) {
  final rawThumb = data['thumbnail'] is String
      ? data['thumbnail'] as String
      : null;
  final description = data['description'] as String? ?? '';
  return MastodonInstancePreview(
    name: data['title'] as String?,
    description: description.isNotEmpty
        ? description
        : data['short_description'] as String? ?? '',
    imageCandidates: [
      (isDefaultMastodonThumbnail(rawThumb) ? null : rawThumb, true),
    ],
  );
}

/// Mastodon の thumbnail が未設定時のバンドルデフォルト preview 画像かを
/// 判定する (#658)。デフォルトは `/packs/.../preview-<hash>.png` のように
/// webpack/Vite の bundle assets 配下に preview ファイル名で置かれる。管理者が
/// アップロードしたカスタム thumbnail は `/site_uploads/` 配下なので preview
/// ファイル名にはならず、ここで false になる。
bool isDefaultMastodonThumbnail(String? url) {
  if (url == null || url.isEmpty) return false;
  final path = Uri.tryParse(url)?.path ?? url;
  final base = path.split('/').last;
  return path.contains('/packs/') && base.startsWith('preview');
}

/// Mastodon `/api/v2/instance` の `icon[]`（PWA アイコン配列）から 192px を
/// 優先で選ぶ。無ければ最大サイズ。マスコットは API に無いためこれで代替 (#658)。
String? mastodonIcon192(dynamic icons) {
  if (icons is! List) return null;
  String? best;
  int bestWidth = 0;
  for (final entry in icons) {
    if (entry is! Map) continue;
    final src = entry['src'] as String?;
    if (src == null || src.isEmpty) continue;
    final width =
        int.tryParse((entry['size'] as String?)?.split('x').first ?? '') ?? 0;
    if (width == 192) return src;
    if (width > bestWidth) {
      bestWidth = width;
      best = src;
    }
  }
  return best;
}

import 'package:capsicum_core/capsicum_core.dart';

/// 投稿本文に付けるナウプレのタグ。既存の共有（push）動線
/// （compose_screen の `#nowplaying ${sharedText}`）と揃える。
const _nowPlayingTag = '#nowplaying';

/// [NowPlayingInfo] を投稿本文用テキストに整形する **capsicum 側フォールバック**
/// 整形 (#466 / v1.33)。
///
/// 整形は本来 2 段（design §URL を持つ源と持たない源）:
///
/// 1. モロヘイヤ `text_nowplaying_formatter`（mulukhiya #4382）— プリセット
///    サーバーで title/artist/album を渡して整形済みテキストを得る。
/// 2. 本関数 — モロヘイヤ未配備サーバー / オフライン用の最低限フォールバック。
///    これが無いと「モロヘイヤありき」になり、#466 の「未配備でも動く」制約を
///    満たせない。
///
/// 方針:
/// - [NowPlayingInfo.url] が非 null（Spotify 等）→ URL をそのまま載せる。
///   SNS / モロヘイヤが unfurl するので文字整形は不要。
/// - URL が無い（MPRIS / SMTC）→ `title / artist` を組む。どちらか欠ければ
///   ある方だけ。両方欠ければ最後の手段として源アプリ名を使う。
String formatNowPlayingFallback(NowPlayingInfo info) {
  final url = info.url;
  if (url != null) {
    return '$_nowPlayingTag $url';
  }

  final parts = <String>[
    for (final s in [info.title, info.artist])
      if (s != null && s.trim().isNotEmpty) s.trim(),
  ];

  if (parts.isEmpty) {
    // title も artist も無い。せめて源アプリ名を出す（"VLC で再生中" 相当の
    // 情報をゼロにしないため）。それも空なら裸のタグ。
    final source = info.sourceAppName.trim();
    return source.isEmpty ? _nowPlayingTag : '$_nowPlayingTag $source';
  }

  return '$_nowPlayingTag ${parts.join(' / ')}';
}

import 'dart:ui' show ImageFilter;

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/preferences_provider.dart';
import '../util/fediverse_link.dart';

/// 本文中の URL に付くプレビューカード（OGP）。
///
/// ⚠ **このカードは「見た目」だけの部品ではない。**タイムラインのタイル高さを
/// 動かす経路を 2 本持っており、どちらもスクロール位置の跳ね (#1032) に効く。
/// 詳細は [_imageHeight] と `build` の幅指定に書いたコメントを参照。
///
/// post_tile.dart から切り出してあるのは、**実物をレンダリングして検証できる
/// ようにするため**（private のままだと widget test から触れない）。高さ・幅の
/// 不変条件は [preview_card_frame_test.dart] が固定している。
class PreviewCardWidget extends ConsumerWidget {
  final PreviewCard card;

  const PreviewCardWidget({super.key, required this.card});

  /// OGP 画像の表示高さ。**読み込みの成否によらずこの高さを保つ**（#1032）。
  static const double imageHeight = 160;

  /// 読み込み失敗時のプレースホルダを検査から一意に掴むための鍵。
  /// カードは Container が入れ子になるので、型で探すと外枠と区別できない。
  static const imagePlaceholderKey = Key('preview-card-image-placeholder');

  /// OGP 画像が読めなかったときのプレースホルダ。
  ///
  /// ⚠ **ここで `SizedBox.shrink()` を返してはいけない。**カードの高さが
  /// 160px 分いきなり縮み、タイムラインのタイル高さが揺れる。
  /// `RenderSliverList` は未生成タイルの高さを「生成済みタイルの平均 × 残り
  /// 件数」で推定するため、平均が数 px 動くだけで推定がずれ、
  /// `scrollOffsetCorrection` が出る。上へ戻るときにスクロール位置が跳ねる
  /// 主因がこれだった（#1032。実機計測で ±160.0px の変動を 29 件確認）。
  ///
  /// 読み込み中は `Image.network` に width / height を渡してあるぶんで枠が
  /// 保たれるので、潰れるのは失敗経路だけ。
  Widget _buildImagePlaceholder(ThemeData theme) {
    return Container(
      key: imagePlaceholderKey,
      width: double.infinity,
      height: imageHeight,
      color: theme.colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.broken_image_outlined),
    );
  }

  Widget _buildImage(ThemeData theme, PreviewCardMode mode) {
    final image = Image.network(
      card.imageUrl!,
      width: double.infinity,
      height: imageHeight,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => _buildImagePlaceholder(theme),
    );
    // blur 時のみ filter を被せる。非 blur 時に identity (no-op) の filter を
    // 被せると render が黒に落ちる事例があるため（#491・添付画像側と同じ扱い）。
    if (mode != PreviewCardMode.blur) return image;
    return ClipRect(
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: image,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(previewCardModeProvider);
    if (mode == PreviewCardMode.hide) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return GestureDetector(
      // ⚠ **ブラウザへ直接送らない（#1030）。**本文中の URL と同じ
      // [openFediverseLink] に通す。カードが指す先は外部サイトとは限らず、
      // 自ホストの Misskey Play (#830) や fediverse の投稿 / アカウント
      // (#820) のこともある。直接 `launchInPreferredApp` を呼んでいたため、
      // Play を指すカードが**アプリ内の Play 画面ではなく WebUI で開いて**
      // いた。リンクのルーティングはアプリ内のどこでも同じであること。
      onTap: () => openFediverseLink(context, ref, card.url),
      child: Container(
        // ⚠ 幅を明示する（#1033）。`Column` の幅は子の最大幅で決まるので、
        // これが無いと横幅を広げているのが `Image.network` だけになり、
        // **OGP 画像を持たないカードだけ本文なりに細くなる**。
        // ⚠ 見た目だけの話ではない。幅が縮むとタイトル (maxLines: 2) と
        // 説明 (maxLines: 3) の折り返しが上限内で 1 行ずつ増え、カードの高さも
        // 40px 前後動く。つまり #1032 の跳ねにも効く。
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (card.imageUrl != null) _buildImage(theme, mode),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    card.title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (card.description != null &&
                      card.description!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      card.description!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

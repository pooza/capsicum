import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../model/account.dart';
import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../util/pages_error.dart';
import 'content_parser.dart';
import 'post_tile.dart';

/// Pages の image/audio/video ブロック読み込み失敗の captureException 抑制用
/// throttle (#629)。breadcrumb は毎回出すが、同種失敗 spam で Sentry が
/// 埋まるのを避けるため exception 送信側だけ間引く。
DateTime? _lastBlockMediaCapture;
const _blockMediaCaptureThrottle = Duration(seconds: 60);

/// Misskey Page の image / audio / video ブロックの素材ロード失敗を観測する
/// (#629)。breadcrumb は毎回、`reportPagesOpFailure` (= captureException) は
/// throttle して送る。URL は host のみを breadcrumb data に載せ (full URL は
/// クエリパラメータに `?i=<token>` が乗りうるため避ける)、自前サーバの CDN
/// 失敗か外部ファイルかの切り分けに使う。
void _reportPageBlockMediaLoadFailure({
  required String url,
  required AttachmentType attachmentType,
  required Object error,
  required StackTrace stackTrace,
  required Account? account,
}) {
  Sentry.addBreadcrumb(
    Breadcrumb(
      category: 'pages.block.media_load',
      level: SentryLevel.warning,
      message: error.runtimeType.toString(),
      data: {
        'attachment_type': attachmentType.name,
        'url_host': Uri.tryParse(url)?.host ?? '',
      },
    ),
  );
  final now = DateTime.now();
  if (_lastBlockMediaCapture != null &&
      now.difference(_lastBlockMediaCapture!) < _blockMediaCaptureThrottle) {
    return;
  }
  _lastBlockMediaCapture = now;
  reportPagesOpFailure('block_media_load', error, stackTrace, account: account);
}

/// Misskey Page (#186) のブロック配列を再帰的にレンダリングするウィジェット。
///
/// v1 で対応するブロック種別:
/// - `section`: 見出し + 子ブロックの入れ子
/// - `text`: MFM テキスト
/// - `image`: 画像 (Page.attachedFiles の fileId 索引から URL を引く)
/// - `note`: Note 埋め込み (PostTile を埋める)
///
/// 上記以外は 2 通りに分けて表示する (#616):
///
/// - **廃止済みの動的ブロック** (button / textInput / numberInput / switch /
///   counter / radioButton / canvas / post / textarea / if): 本家が既に
///   「廃止されています。今後は Play を利用してください。」の案内に倒して
///   おり、エディタからも作成できない。capsicum も同じ案内を出す
///   ([_kDeprecatedBlockTypes] / [_DeprecatedBlock])
/// - **それ以外の未知の type**: capsicum が追いついていない可能性があるので
///   「未対応です」と type 名を出す ([_UnsupportedBlock])
class PageBlockRenderer extends ConsumerWidget {
  final List<Map<String, dynamic>> blocks;
  final Map<String, Attachment> attachedFiles;
  final String? host;

  const PageBlockRenderer({
    super.key,
    required this.blocks,
    this.attachedFiles = const {},
    this.host,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: blocks
          .map(
            (b) =>
                _PageBlock(block: b, attachedFiles: attachedFiles, host: host),
          )
          .toList(growable: false),
    );
  }
}

class _PageBlock extends ConsumerWidget {
  final Map<String, dynamic> block;
  final Map<String, Attachment> attachedFiles;
  final String? host;

  const _PageBlock({
    required this.block,
    required this.attachedFiles,
    this.host,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = block['type'] as String? ?? '';
    switch (type) {
      case 'section':
        return _SectionBlock(
          block: block,
          attachedFiles: attachedFiles,
          host: host,
        );
      case 'text':
        return _TextBlock(block: block, host: host);
      case 'image':
        return _ImageBlock(
          block: block,
          attachedFiles: attachedFiles,
          host: host,
        );
      case 'note':
        return _NoteBlock(block: block);
      default:
        return _kDeprecatedBlockTypes.contains(type)
            ? const _DeprecatedBlock()
            : _UnsupportedBlock(type: type);
    }
  }
}

/// Misskey 本家が **廃止済み**として扱っている動的ブロックの type 一覧 (#616)。
///
/// 本家の `packages/frontend/src/components/page/page.block.vue` はこれらを
/// すべて「廃止されています」の案内 (`page.dynamic.vue`) にフォールバック
/// させており、`page-editor/common.ts` が提供するブロックも section / text /
/// image / note の 4 種のみで **新規作成もできない**。したがって capsicum が
/// AiScript で描画する意味がなく、本家と同じ案内を出すに留める。
///
/// 「未対応 (`_UnsupportedBlock`)」と区別するのが本 issue の目的。前者は
/// capsicum が追いついていないことを示唆するが、これらは追いついても
/// 意味がない（本家でも表示されない）ため、案内の意味が違う。
const _kDeprecatedBlockTypes = {
  'button',
  'if',
  'textarea',
  'post',
  'canvas',
  'numberInput',
  'textInput',
  'switch',
  'radioButton',
  'counter',
};

class _SectionBlock extends StatelessWidget {
  final Map<String, dynamic> block;
  final Map<String, Attachment> attachedFiles;
  final String? host;

  const _SectionBlock({
    required this.block,
    required this.attachedFiles,
    this.host,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = block['title'] as String? ?? '';
    final children = ((block['children'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          PageBlockRenderer(
            blocks: children,
            attachedFiles: attachedFiles,
            host: host,
          ),
        ],
      ),
    );
  }
}

class _TextBlock extends ConsumerStatefulWidget {
  final Map<String, dynamic> block;
  final String? host;

  const _TextBlock({required this.block, this.host});

  @override
  ConsumerState<_TextBlock> createState() => _TextBlockState();
}

class _TextBlockState extends ConsumerState<_TextBlock> {
  ContentRenderer? _renderer;
  // ContentRenderer の生成入力をキャッシュし、変化したときだけ作り直す (#628)。
  // build ごとの dispose + 再生成は emojiSize provider 変更等で頻発し GC 負荷に
  // なる。emojiSize は Riverpod 依存で InheritedWidget ではないため
  // didChangeDependencies では拾えず、入力メモ化で「依存変化時のみ再生成」を
  // 実現する。
  TextStyle? _baseStyle;
  double? _emojiSize;
  String? _host;

  @override
  void dispose() {
    _renderer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = widget.block['text'] as String? ?? '';
    if (text.isEmpty) return const SizedBox.shrink();

    final baseStyle = theme.textTheme.bodyMedium ?? const TextStyle();
    final emojiSize = ref.watch(emojiSizeProvider);
    if (_renderer == null ||
        _baseStyle != baseStyle ||
        _emojiSize != emojiSize ||
        _host != widget.host) {
      _renderer?.dispose();
      _renderer = ContentRenderer(
        baseStyle: baseStyle,
        resolveEmoji: (shortcode) {
          if (widget.host != null) {
            return 'https://${widget.host}/emoji/$shortcode.webp';
          }
          return null;
        },
        emojiSize: emojiSize,
        animateMfm: ref.watch(mfmAnimationEnabledProvider),
      );
      _baseStyle = baseStyle;
      _emojiSize = emojiSize;
      _host = widget.host;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text.rich(_renderer!.renderMfm(text)),
    );
  }
}

class _ImageBlock extends ConsumerWidget {
  final Map<String, dynamic> block;
  final Map<String, Attachment> attachedFiles;
  final String? host;

  const _ImageBlock({
    required this.block,
    required this.attachedFiles,
    this.host,
  });

  void _openMediaViewer(BuildContext context, Attachment file) {
    context.push(
      '/media',
      extra: {
        'attachments': <Attachment>[file],
        'initialIndex': 0,
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Misskey の「image」ブロックは命名と裏腹にドライブ内の任意ファイル
    // (動画 / 音声含む) を貼れる仕様。Attachment.type で分岐し、post_tile の
    // 動画/音声サムネ規約 (previewUrl 優先・無し動画は黒フレーム回避の
    // プレースホルダ・タップで MediaViewer) と揃える。
    final fileId = block['fileId'] as String? ?? '';
    final file = attachedFiles[fileId];
    final theme = Theme.of(context);
    if (file == null || file.url.isEmpty) {
      return _placeholder(
        context: context,
        icon: Icons.image_not_supported,
        text: '画像を読み込めません',
      );
    }
    if (file.type == AttachmentType.audio) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: GestureDetector(
          onTap: () => _openMediaViewer(context, file),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.music_note, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    file.description ?? file.name ?? '音声',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final isVideoLike =
        file.type == AttachmentType.video || file.type == AttachmentType.gifv;
    final hasPreview = file.previewUrl != null && file.previewUrl!.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: GestureDetector(
        onTap: () => _openMediaViewer(context, file),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 動画 / gifv で preview_url が無いと Image.network が黒フレーム
              // を返す (post_tile の #491 と同じ事象)。プレースホルダに倒す。
              if (isVideoLike && !hasPreview)
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Container(
                    color: theme.colorScheme.surfaceContainerHighest,
                  ),
                )
              else
                Image.network(
                  file.previewUrl ?? file.url,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stack) {
                    _reportPageBlockMediaLoadFailure(
                      url: file.previewUrl ?? file.url,
                      attachmentType: file.type,
                      error: error,
                      stackTrace: stack ?? StackTrace.current,
                      account: ref.read(currentAccountProvider),
                    );
                    return Container(
                      padding: const EdgeInsets.all(16),
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Text(
                        isVideoLike ? '動画を表示できません' : '画像の表示に失敗しました',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    );
                  },
                ),
              if (isVideoLike)
                const Icon(
                  Icons.play_circle_outline,
                  color: Colors.white70,
                  size: 48,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder({
    required BuildContext context,
    required IconData icon,
    required String text,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, color: theme.colorScheme.outline),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoteBlock extends ConsumerStatefulWidget {
  final Map<String, dynamic> block;

  const _NoteBlock({required this.block});

  @override
  ConsumerState<_NoteBlock> createState() => _NoteBlockState();
}

class _NoteBlockState extends ConsumerState<_NoteBlock> {
  Future<Post>? _future;
  String? _noteId;

  @override
  void initState() {
    super.initState();
    _maybeFetch();
  }

  @override
  void didUpdateWidget(_NoteBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeFetch();
  }

  void _maybeFetch() {
    final noteId = widget.block['note'] as String?;
    if (noteId == _noteId) return;
    _noteId = noteId;
    if (noteId == null || noteId.isEmpty) {
      _future = null;
      return;
    }
    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) {
      _future = null;
      return;
    }
    _future = adapter.getPostById(noteId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_future == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          '埋め込み投稿を読み込めません',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: FutureBuilder<Post>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '埋め込み投稿の取得に失敗しました',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            );
          }
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: PostTile(post: snapshot.data!),
          );
        },
      ),
    );
  }
}

/// Misskey 本家で廃止済みの動的ブロック用のプレースホルダ (#616)。
///
/// 文言は本家の `page.dynamic.vue`（見出し「動的ブロック」+ 「このブロックは
/// 廃止されています。今後は Play を利用してください。」）に合わせる。
/// UI 表記は本家に揃えて **Play**（内部のエンティティ名は Flash）。
class _DeprecatedBlock extends StatelessWidget {
  const _DeprecatedBlock();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.5,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.casino_outlined,
              size: 16,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '動的ブロック',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'このブロックは廃止されています。今後は Play を利用してください。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnsupportedBlock extends StatelessWidget {
  final String type;

  const _UnsupportedBlock({required this.type});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = type.isEmpty ? '(unknown)' : type;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.5,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Icon(
              Icons.extension_off,
              size: 16,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'このブロックは未対応です ($label)',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

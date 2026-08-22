import 'dart:async';
import 'dart:io';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../../platform/platform_info.dart';
import '../../provider/account_manager_provider.dart';
import '../util/attachment_description_edit.dart';
import '../../service/sentry_op_failure.dart';
import '../../util/media_filename.dart';

/// メディア URL を Sentry breadcrumb に載せる際、クエリ（署名トークンや
/// プロキシ token を含みうる）を落として host + path のみに切り詰める。
/// attachment.url は通例公開 CDN URL だが、token 付き URL を返す実装でも
/// 機密がそのまま Sentry に転載されないようにする (#649 followup)。
String _scrubMediaUrl(String url) {
  try {
    final uri = Uri.parse(url);
    return '${uri.host}${uri.path}';
  } catch (_) {
    return '(unparsable)';
  }
}

/// drag-out (#645) で OS に渡す virtual file の形式を添付の拡張子から決める。
/// 既知の画像形式のみ対応し、未知の拡張子は null を返して drag-out 自体を
/// 無効化する（誤った形式で壊れたファイルを渡さない）。動画/音声は player の
/// 操作と gesture が競合するため別途・現状は対象外。
///
/// 判定には [suggestedMediaFileName] のデフォルト拡張子に頼らず生の拡張子
/// ([rawMediaExtension]) を使う。前者は拡張子の無い添付に既定 `.png` を当てるため、
/// 実バイトが JPEG/WebP でも PNG として advertise してしまう (#779)。生の拡張子が
/// 無い＝形式不明なら drag-out を無効化する。
FileFormat? _dragOutFileFormat(Attachment attachment) {
  if (attachment.type != AttachmentType.image) return null;
  switch (rawMediaExtension(attachment)) {
    case 'png':
    case 'apng':
      return Formats.png;
    case 'jpg':
    case 'jpeg':
      return Formats.jpeg;
    case 'gif':
      return Formats.gif;
    case 'webp':
      return Formats.webp;
    default:
      return null;
  }
}

class MediaViewerScreen extends ConsumerStatefulWidget {
  final List<Attachment> attachments;
  final int initialIndex;
  final String? postAuthorId;
  final String? postId;

  const MediaViewerScreen({
    super.key,
    required this.attachments,
    this.initialIndex = 0,
    this.postAuthorId,
    this.postId,
  });

  @override
  ConsumerState<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends ConsumerState<MediaViewerScreen> {
  late final PageController _pageController;
  late int _currentIndex;
  late List<Attachment> _attachments;
  bool _modified = false;

  /// 現在ページの画像がピンチズーム中か (#848 item1)。ズーム中は PageView の
  /// スワイプを止めて（`NeverScrollableScrollPhysics`）pan とページ送りが競合
  /// しないようにする。ズーム倍率 1 に戻れば false になり、横スワイプで全域
  /// ページ送りに戻る。ページ送り時は下の onPageChanged で false にリセットする。
  bool _zoomed = false;

  void _setZoomed(bool zoomed) {
    if (_zoomed != zoomed) setState(() => _zoomed = zoomed);
  }

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _attachments = List.of(widget.attachments);
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// ALT 編集の導線を出すか。
  ///
  /// ⚠ **Mastodon はモロヘイヤ導入済みサーバーに限る** (#121)。Mastodon には
  /// 投稿済み添付の説明だけを変える API が無く、投稿の更新 API を使うしかない。
  /// その API は「送らなかったパラメータ」を現状維持ではなく**空で更新**として
  /// 扱うため、素で呼ぶと **添付が全部外れ CW と閲覧注意も消える**
  /// （mulukhiya#4589）。現状維持すべき値を補完するのはモロヘイヤ 5.34.0 以降の
  /// 役目なので、**モロヘイヤが `features.media_update` を名乗らない環境では
  /// 導線ごと出さない**（#999 / mulukhiya#4636）。
  ///
  /// 判定を UI 層に置いているのは、アダプタからモロヘイヤの有無が見えないため
  /// （`MulukhiyaService` は `Account` が持つアプリ層の資産）。`TranslationSupport`
  /// を `adapter is! MastodonAdapter || adapter.isTranslationAvailable` で
  /// 出し分けている `post_tile` と同じ形。
  ///
  /// Misskey は `drive/files/update` が投稿済みでも効くので無条件で出す。
  bool get _canEdit {
    final currentUser = ref.read(currentAccountProvider)?.user;
    final adapter = ref.read(currentAdapterProvider);
    final mulukhiya = ref.read(currentMulukhiyaProvider);
    return canEditAttachmentDescription(
      supportsMediaUpdate: adapter is MediaUpdateSupport,
      needsMulukhiya: adapter is MastodonAdapter,
      hasMulukhiya: mulukhiya != null,
      // ⚠ **版まで見る (#999)。**5.33.0 は media_update を受理するが補完しない
      // ので、有無だけで出すと投稿から添付が全部外れ CW も消える。
      mulukhiyaHandlesMediaUpdate: mulukhiyaSupportsMediaUpdate(
        mulukhiya?.version,
      ),
      isOwnPost: currentUser != null && currentUser.id == widget.postAuthorId,
      hasPostContext: widget.postAuthorId != null && widget.postId != null,
    );
  }

  Future<void> _editDescription() async {
    final attachment = _attachments[_currentIndex];
    final controller = TextEditingController(
      text: attachment.description ?? '',
    );

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('メディアの説明を編集'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: '説明を入力…',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result == null || !mounted) return;

    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! MediaUpdateSupport) return;
    final mediaSupport = adapter as MediaUpdateSupport;

    try {
      await mediaSupport.updateAttachmentDescription(
        attachment.id,
        result,
        postId: widget.postId!,
      );
      setState(() {
        _attachments[_currentIndex] = Attachment(
          id: attachment.id,
          type: attachment.type,
          url: attachment.url,
          previewUrl: attachment.previewUrl,
          description: result,
        );
        _modified = true;
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('説明を更新しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('更新に失敗しました')));
      }
    }
  }

  void _popWithResult() {
    if (_modified) {
      context.pop(_attachments);
    } else {
      context.pop();
    }
  }

  /// 指定ページへアニメーションで送る。範囲外は無視する。onPageChanged 経由で
  /// _currentIndex が更新される。
  void _goToPage(int index) {
    if (index < 0 || index >= _attachments.length) return;
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// 左右キーで前後のメディアへ送る (#848)。デスクトップ / 外付けキーボード向け。
  /// 単一メディアや修飾キー付きは無視する。リピート（長押し）でも送る。
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_attachments.length < 2) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _goToPage(_currentIndex - 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _goToPage(_currentIndex + 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// デスクトップ 3 OS は file_selector の保存ダイアログでローカル保存 (#572
  /// 第一弾)。ファイラーへの drag-out は別 issue (#645)。
  bool get _canSaveToDisk => isDesktop;

  /// モバイル (iOS / Android) はカメラロール / ギャラリーへ保存 (#646)。
  /// gal が扱えるのは画像と動画のみで、音声はギャラリーの概念に無いため
  /// 対象外 (デスクトップの保存ダイアログ側は従来どおり音声も保存可)。
  bool _canSaveToGallery(Attachment attachment) {
    if (isDesktop) return false;
    switch (attachment.type) {
      case AttachmentType.image:
      case AttachmentType.video:
      case AttachmentType.gifv:
        return true;
      case AttachmentType.audio:
      case AttachmentType.unknown:
        return false;
    }
  }

  /// 現在表示中のメディアを保存する。デスクトップは OS のファイル保存
  /// ダイアログ (#572)、モバイルはカメラロール / ギャラリー (#646)。
  Future<void> _saveMedia() async {
    if (isDesktop) {
      await _saveMediaToDisk();
    } else {
      await _saveMediaToGallery();
    }
  }

  /// file_selector の保存ダイアログで保存先を選び、dio で取得して書き出す
  /// (#572)。
  Future<void> _saveMediaToDisk() async {
    final attachment = _attachments[_currentIndex];
    final suggestedName = suggestedMediaFileName(attachment);
    // ref.read は await をまたぐ前に退避する (#698 / #665 同型)。catch で
    // mounted ガード前に ref を触らないため、失敗計装用の account を先に取る。
    final account = ref.read(currentAccountProvider);

    final FileSaveLocation? location = await getSaveLocation(
      suggestedName: suggestedName,
    );
    if (location == null || !mounted) return; // ユーザーがキャンセル

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('保存しています…')));

    try {
      final bytes = await _downloadBytes(attachment.url);
      await File(location.path).writeAsBytes(bytes);
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(const SnackBar(content: Text('保存しました')));
    } catch (e, st) {
      // #572 は新機能のため初期は計装する。権限・ディスク full・サーバ 4xx 等の
      // ダウンロード / 書き込み失敗を host/backend tag 付きで観測する (#648)。
      reportOpFailure(
        tagKey: 'media.op',
        operation: 'save',
        error: e,
        stackTrace: st,
        account: account,
      );
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(const SnackBar(content: Text('保存に失敗しました')));
    }
  }

  /// gal でカメラロール / ギャラリーへ保存する (#646)。ネットワーク上の
  /// メディアを一時ファイルに落としてから putImage / putVideo に渡す
  /// (gal はファイルパス入力のため)。
  Future<void> _saveMediaToGallery() async {
    final attachment = _attachments[_currentIndex];
    final messenger = ScaffoldMessenger.of(context);
    // ref.read は await をまたぐ前に退避する (#698 / #665 同型)。
    final account = ref.read(currentAccountProvider);

    // iOS は NSPhotoLibraryAddUsageDescription の追加許可、Android API 28
    // 以下は WRITE_EXTERNAL_STORAGE をここで要求する (API 29+ は常に true)。
    final hasAccess = await Gal.hasAccess() || await Gal.requestAccess();
    if (!mounted) return;
    if (!hasAccess) {
      messenger.showSnackBar(
        const SnackBar(content: Text('フォトライブラリへのアクセスが許可されていません')),
      );
      return;
    }

    messenger.showSnackBar(const SnackBar(content: Text('保存しています…')));

    File? tempFile;
    try {
      final bytes = await _downloadBytes(attachment.url);
      final tempDir = await getTemporaryDirectory();
      tempFile = File('${tempDir.path}/${suggestedMediaFileName(attachment)}');
      await tempFile.writeAsBytes(bytes);
      final isVideo =
          attachment.type == AttachmentType.video ||
          attachment.type == AttachmentType.gifv;
      if (isVideo) {
        await Gal.putVideo(tempFile.path);
      } else {
        await Gal.putImage(tempFile.path);
      }
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(const SnackBar(content: Text('保存しました')));
    } catch (e, st) {
      // デスクトップ保存 (#648) と同じ計装。権限拒否はユーザー操作の範疇
      // なので Sentry には送らない。
      final denied =
          e is GalException && e.type == GalExceptionType.accessDenied;
      if (!denied) {
        reportOpFailure(
          tagKey: 'media.op',
          operation: 'save_gallery',
          error: e,
          stackTrace: st,
          account: account,
        );
      }
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(denied ? 'フォトライブラリへのアクセスが許可されていません' : '保存に失敗しました'),
        ),
      );
    } finally {
      // 一時ファイルは best-effort で掃除する (失敗しても OS が回収する領域)。
      try {
        await tempFile?.delete();
      } catch (_) {}
    }
  }

  Future<List<int>> _downloadBytes(String url) async {
    final response = await Dio().get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final bytes = response.data;
    if (bytes == null) {
      throw const FormatException('empty response body');
    }
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    final attachment = _attachments[_currentIndex];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _popWithResult();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.black54,
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _popWithResult,
          ),
          title: widget.attachments.length > 1
              ? Text('${_currentIndex + 1} / ${widget.attachments.length}')
              : null,
          actions: [
            if (_canSaveToDisk || _canSaveToGallery(attachment))
              IconButton(
                icon: const Icon(Icons.download_outlined),
                tooltip: '保存',
                onPressed: _saveMedia,
              ),
            if (_canEdit)
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'メディアの説明を編集',
                onPressed: _editDescription,
              ),
          ],
        ),
        body: Focus(
          autofocus: true,
          onKeyEvent: _handleKey,
          child: Stack(
            children: [
              PageView.builder(
                controller: _pageController,
                // ズーム中はページ送りを止め、pan（画像の移動）だけを効かせる
                // (#848 item1)。ズーム倍率 1 では通常スクロールに戻す。
                physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
                itemCount: _attachments.length,
                onPageChanged: (index) => setState(() {
                  _currentIndex = index;
                  // 新しいページは倍率 1 から始まるため、ズーム状態をリセット
                  // してスワイプを再開できるようにする。
                  _zoomed = false;
                }),
                itemBuilder: (context, index) {
                  final a = _attachments[index];
                  if (a.type == AttachmentType.video ||
                      a.type == AttachmentType.gifv) {
                    return _VideoPage(url: a.url);
                  }
                  if (a.type == AttachmentType.audio) {
                    return _AudioPage(url: a.url);
                  }
                  final image = Image.network(
                    a.url,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white54,
                      size: 64,
                    ),
                  );
                  // デスクトップ (macOS / Windows / Linux) では画像を OS ファイラーへ
                  // drag-out できる (#645 / #776)。画像のみ (動画/音声は player の
                  // 操作と gesture が競合するため対象外)。macOS / Windows は virtual
                  // file、Linux は temp 実ファイル経路（_DragOutImage 内で分岐）。
                  final draggable =
                      supportsMediaDragOut && _dragOutFileFormat(a) != null
                      ? _DragOutImage(
                          attachment: a,
                          download: _downloadBytes,
                          onDownloadError: (e, st) => reportOpFailure(
                            tagKey: 'media.op',
                            operation: 'drag_out',
                            error: e,
                            stackTrace: st,
                            account: ref.read(currentAccountProvider),
                          ),
                          child: image,
                        )
                      : image;
                  return _ZoomableImagePage(
                    onZoomChanged: _setZoomed,
                    child: draggable,
                  );
                },
              ),
              if (attachment.description != null &&
                  attachment.description!.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Colors.black87, Colors.transparent],
                      ),
                    ),
                    padding: EdgeInsets.fromLTRB(
                      16,
                      32,
                      16,
                      MediaQuery.of(context).padding.bottom + 16,
                    ),
                    child: Text(
                      attachment.description!,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// PageView 内で pinch ズームできる画像 1 枚 (#848 item1)。
///
/// ズーム倍率 1 のときは [InteractiveViewer] の pan を無効化し、横ドラッグを
/// 親の [PageView] に流す。これにより画像の上だけでなく **黒帯部分を含む
/// ビューア全域**でページ送りができる（従来は InteractiveViewer が倍率 1 でも
/// 横ドラッグを掴んでしまい、「画像の上でしか反応しない／ドラッグだと渋い」
/// 感触の一因になっていた）。ズーム中のみ pan を有効化し、併せて
/// [onZoomChanged] で親にズーム状態を通知して PageView のスワイプを止める。
class _ZoomableImagePage extends StatefulWidget {
  final Widget child;
  final ValueChanged<bool> onZoomChanged;

  const _ZoomableImagePage({required this.child, required this.onZoomChanged});

  @override
  State<_ZoomableImagePage> createState() => _ZoomableImagePageState();
}

class _ZoomableImagePageState extends State<_ZoomableImagePage> {
  final TransformationController _controller = TransformationController();
  bool _zoomed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 現在の変換行列からズーム中か判定し、変化があれば pan の有効/無効
  /// （再ビルド）と親への通知に反映する。1.01 は倍率 1 の浮動小数ノイズを
  /// ズーム扱いしないための閾値。
  void _syncZoom() {
    final zoomed = _controller.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) {
      setState(() => _zoomed = zoomed);
      widget.onZoomChanged(zoomed);
    }
  }

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      transformationController: _controller,
      minScale: 1.0,
      maxScale: 4.0,
      // 倍率 1 では pan を無効化して横ドラッグを PageView に委ねる。ピンチ
      // (scale) は常に有効なので、この状態からでもズーム開始できる。
      panEnabled: _zoomed,
      onInteractionUpdate: (_) => _syncZoom(),
      onInteractionEnd: (_) => _syncZoom(),
      child: Center(child: widget.child),
    );
  }
}

/// drag-out の Linux 用 temp 実ファイルを置く一意な副ディレクトリ名の連番
/// (#776)。同一添付を続けてドラッグしても衝突せず、掃除時に別ドラッグの
/// ファイルを取り違えて消さないため、毎回インクリメントして使う。
int _dragOutTempSeq = 0;

/// Linux drag-out の temp 実ファイルを置くベースディレクトリ名 (#776)。
const _dragOutTempDirName = 'capsicum_dragout';

/// 画像を OS ファイラー（Finder / Explorer / Nautilus）へ drag-out する wrapper
/// (#645 / #776)。ネットワーク画像を OS がファイルとして受け取れるようにする。
/// デスクトップ 3 OS が対象（[supportsMediaDragOut]）で、渡し方を OS 能力で分岐:
///
/// - **macOS / Windows**（[DragItem.virtualFileSupported] が true）: virtual file
///   （遅延ファイル生成）。ダウンロードは drop 時に呼ばれる virtual file provider
///   内で行い、[dragItemProvider] は同期で DragItem を返す（await しない）。
///   Windows の OLE ドラッグ（DoDragDrop）はジェスチャー内で同期的に開始する
///   必要があり、開始前に await（ネットワーク取得）が挟まるとドラッグが起動したり
///   しなかったりするため（drag-out が間欠的に不成立）。virtual file provider は
///   「DL 等で時間がかかる on-demand 生成」を想定した API なので、取得はここに
///   置くのが本来の設計（README / addVirtualFile の doc 参照）。取得失敗時は
///   addError で空ファイルを残さず中断する。
/// - **Linux (GTK)**: virtual file 非対応のため、ドラッグ開始時に temp へ実ファイル
///   を書き出し、その file URI（`text/uri-list`）を渡す（#776）。[DragItemProvider]
///   は `FutureOr` を許すので、この経路だけ provider が Future を返す（GTK は OLE の
///   ような同期開始制約が無い）。取得失敗時は item を返さずドラッグを不成立にする。
///   temp の掃除は **ドロップ完了時に即消さず**、次のドラッグ開始時に前回分を消す
///   遅延方式にする。file URI 方式では受け側（特に pcmanfm-qt 等の Qt ファイラ）が
///   XdndFinished を返した後に実ファイルをコピーする実装があり、`onDisposed` で
///   即削除するとコピー前に消えてドロップが不成立になるため（#776）。
///
/// 画像用途に限定し、動画/音声は player の操作 gesture と競合するため対象外。
class _DragOutImage extends StatelessWidget {
  final Attachment attachment;
  final Future<List<int>> Function(String url) download;
  final void Function(Object error, StackTrace stackTrace) onDownloadError;
  final Widget child;

  const _DragOutImage({
    required this.attachment,
    required this.download,
    required this.onDownloadError,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return DragItemWidget(
      allowedOperations: () => const [DropOperation.copy],
      canAddItemToExistingSession: true,
      dragItemProvider: (request) {
        final format = _dragOutFileFormat(attachment);
        if (format == null) return null;
        final item = DragItem(
          suggestedName: suggestedMediaFileName(attachment),
          localData: attachment.id,
        );
        if (item.virtualFileSupported) {
          item.addVirtualFile(
            format: format,
            // drop 時に遅延ダウンロード。ドラッグ開始時に await しないことが要点
            // （Windows のドラッグ起動を阻害しない）。sinkProvider は取得完了後に
            // ファイルサイズ確定で呼ぶ。
            provider: (sinkProvider, progress) {
              unawaited(() async {
                try {
                  final bytes = await download(attachment.url);
                  final sink = sinkProvider(fileSize: bytes.length);
                  sink.add(Uint8List.fromList(bytes));
                  sink.close();
                } catch (e, st) {
                  // #645 は新機能のため初期は計装し、drag-out 固有の失敗率を
                  // host/backend tag 付きで観測する（save 系 #648 と同じ方針）。
                  onDownloadError(e, st);
                  // 取得失敗時は壊れた / 空ファイルを OS へ残さず中断する。
                  final sink = sinkProvider(fileSize: 0);
                  sink.addError(e);
                }
              }());
            },
          );
          return item;
        }
        // Linux (GTK): virtual file 非対応。実ファイルを書き出してから返す（async）。
        return _provideLinuxFileItem(item);
      },
      child: DraggableWidget(child: child),
    );
  }

  /// Linux 用: 添付を temp へ実ファイルとして書き出し、その file URI を [item] に
  /// 積んで返す (#776)。DL / 書き込み失敗時は計装して null を返し（ドラッグ不成立）、
  /// 空 / 壊れたファイルを OS へ残さない。
  ///
  /// 掃除は遅延方式: **今回のファイルは残し、次回ドラッグ開始時に前回までの temp を
  /// 消す**。ドロップ完了（onDisposed）で即消すと、file URI を受け取った側が
  /// XdndFinished 後にコピーする実装（pcmanfm-qt 等の Qt ファイラ）でコピー前に
  /// ファイルが消えてドロップが不成立になるため。残るのは高々「最後にドラッグした
  /// 1 ファイル」で、次のドラッグ or OS の /tmp 回収で消える。
  Future<DragItem?> _provideLinuxFileItem(DragItem item) async {
    Directory? dir;
    try {
      final bytes = await download(attachment.url);
      final tempDir = await getTemporaryDirectory();
      final baseDir = Directory('${tempDir.path}/$_dragOutTempDirName');
      // 前回までの drag-out temp を先に掃除する（今回作る副ディレクトリより前の分）。
      if (baseDir.existsSync()) {
        for (final entry in baseDir.listSync()) {
          try {
            entry.deleteSync(recursive: true);
          } catch (_) {
            // 使用中 / 権限等で消せなくても致命的でない（/tmp は OS が回収する）。
          }
        }
      }
      dir = Directory('${baseDir.path}/${_dragOutTempSeq++}');
      await dir.create(recursive: true);
      final file = File('${dir.path}/${suggestedMediaFileName(attachment)}');
      await file.writeAsBytes(bytes);
      item.add(Formats.fileUri(Uri.file(file.path)));
      return item;
    } catch (e, st) {
      // #776 も新機能のため計装（macOS/Windows の #645 と同じ media.op tag）。
      onDownloadError(e, st);
      // 途中まで作った temp は残さない。
      dir?.delete(recursive: true).ignore();
      return null;
    }
  }
}

/// 動画 / 音声で共通の進捗バー。media_kit の position / duration を Slider で
/// 表示し、スクラブで seek する。旧 video_player の VideoProgressIndicator
/// 置き換え (#492)。
class _MediaProgressBar extends StatelessWidget {
  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;

  const _MediaProgressBar({
    required this.position,
    required this.duration,
    required this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    final maxMs = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final value = position.inMilliseconds.clamp(0, maxMs.toInt()).toDouble();
    return SliderTheme(
      data: const SliderThemeData(
        trackHeight: 2,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
        activeTrackColor: Colors.white,
        inactiveTrackColor: Colors.white24,
        thumbColor: Colors.white,
      ),
      child: Slider(
        value: value,
        max: maxMs,
        onChanged: (v) => onSeek(Duration(milliseconds: v.round())),
      ),
    );
  }
}

String _formatDuration(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
}

class _VideoPage extends StatefulWidget {
  final String url;

  const _VideoPage({required this.url});

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  late final Player _player;
  late final VideoController _controller;
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _initialized = false;
  bool _playing = false;
  bool _showControls = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _aspectRatio = 16 / 9;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Linux (AppImage) では media_kit 既定の hwdec='auto' が vulkan/VAAPI/v4l2m2m
    // 等のハードウェアデコーダを試して全滅し、ソフトデコードに落ちず映像が
    // デコードされない (#492。mpv ログで `vd: Could not open codec` を確認)。
    // host GPU ドライバ (Intel iHD 等) と AppImage 同梱ライブラリの ABI も
    // 噛み合わない。そこで Linux のみ hwdec='no' でソフトデコードを強制し、
    // 描画も enableHardwareAcceleration=false の S/W 描画にして host の
    // GL/EGL/VAAPI に一切依存させない。macOS/Windows/モバイルは既定の H/W。
    _player = Player();
    _controller = VideoController(
      _player,
      configuration: Platform.isLinux
          ? const VideoControllerConfiguration(
              enableHardwareAcceleration: false,
              hwdec: 'no',
            )
          : const VideoControllerConfiguration(),
    );
    _subs.add(
      _player.stream.playing.listen((playing) {
        if (mounted) setState(() => _playing = playing);
      }),
    );
    _subs.add(
      _player.stream.position.listen((position) {
        if (mounted) setState(() => _position = position);
      }),
    );
    _subs.add(
      _player.stream.duration.listen((duration) {
        if (mounted) setState(() => _duration = duration);
      }),
    );
    _subs.add(_player.stream.width.listen((_) => _updateAspectRatio()));
    _subs.add(_player.stream.height.listen((_) => _updateAspectRatio()));
    // 再生中ストリームの error では画面エラー固定にしない (#649)。mpv は再生中に
    // transient な非致命 error を流すことがあり (特に Linux ソフトデコード経路で
    // ログ警告が error として上がる)、これで `_error` を立てると画面全体が
    // 「動画を読み込めません」に固定され、クリア経路がないまま復帰しなくなる。
    // 致命的な失敗は下の open().catchError で拾えるため、ここでは Sentry の
    // breadcrumb を残すに留め、回帰調査の手がかりだけ確保する。
    _subs.add(
      _player.stream.error.listen((error) {
        Sentry.addBreadcrumb(
          Breadcrumb(
            category: 'media',
            message: 'video stream error',
            level: SentryLevel.warning,
            data: {'error': error, 'url': _scrubMediaUrl(widget.url)},
          ),
        );
      }),
    );
    _player
        .open(Media(widget.url))
        .then((_) {
          if (mounted) {
            setState(() => _initialized = true);
            _hideControlsAfterDelay();
          }
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e.toString());
        });
  }

  void _updateAspectRatio() {
    final w = _player.state.width;
    final h = _player.state.height;
    if (mounted && w != null && h != null && w > 0 && h > 0) {
      setState(() => _aspectRatio = w / h);
    }
  }

  void _hideControlsAfterDelay() {
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _playing) {
        setState(() => _showControls = false);
      }
    });
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    unawaited(_player.dispose());
    super.dispose();
  }

  void _togglePlayPause() {
    if (_playing) {
      _player.pause();
      setState(() => _showControls = true);
    } else {
      _player.play();
      _hideControlsAfterDelay();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white54, size: 48),
            const SizedBox(height: 8),
            Text('動画を読み込めません', style: const TextStyle(color: Colors.white54)),
          ],
        ),
      );
    }

    if (!_initialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Center(
      child: AspectRatio(
        aspectRatio: _aspectRatio,
        child: GestureDetector(
          onTap: () => setState(() => _showControls = !_showControls),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Video(
                controller: _controller,
                controls: NoVideoControls,
                fill: Colors.black,
              ),
              // Play/pause button
              AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: GestureDetector(
                  onTap: _togglePlayPause,
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Colors.black38,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Icon(
                      _playing ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                      size: 48,
                    ),
                  ),
                ),
              ),
              // Bottom control bar
              AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Colors.black54, Colors.transparent],
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(12, 24, 12, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _MediaProgressBar(
                          position: _position,
                          duration: _duration,
                          onSeek: _player.seek,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatDuration(_position),
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              _formatDuration(_duration),
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AudioPage extends StatefulWidget {
  final String url;

  const _AudioPage({required this.url});

  @override
  State<_AudioPage> createState() => _AudioPageState();
}

class _AudioPageState extends State<_AudioPage> {
  late final Player _player;
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _initialized = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _error;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _subs.add(
      _player.stream.playing.listen((playing) {
        if (mounted) setState(() => _playing = playing);
      }),
    );
    _subs.add(
      _player.stream.position.listen((position) {
        if (mounted) setState(() => _position = position);
      }),
    );
    _subs.add(
      _player.stream.duration.listen((duration) {
        if (mounted) setState(() => _duration = duration);
      }),
    );
    // 再生中ストリームの error では画面エラー固定にしない (#649)。動画側と同じく
    // transient error で「音声を読み込めません」に固定されるのを防ぐ。致命的な
    // 失敗は open().catchError で拾い、ここは breadcrumb のみ。
    _subs.add(
      _player.stream.error.listen((error) {
        Sentry.addBreadcrumb(
          Breadcrumb(
            category: 'media',
            message: 'audio stream error',
            level: SentryLevel.warning,
            data: {'error': error, 'url': _scrubMediaUrl(widget.url)},
          ),
        );
      }),
    );
    _player
        .open(Media(widget.url))
        .then((_) {
          if (mounted) setState(() => _initialized = true);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e.toString());
        });
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white54, size: 48),
            const SizedBox(height: 8),
            Text('音声を読み込めません', style: const TextStyle(color: Colors.white54)),
          ],
        ),
      );
    }

    if (!_initialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.music_note, color: Colors.white38, size: 96),
            const SizedBox(height: 32),
            GestureDetector(
              onTap: _player.playOrPause,
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.white12,
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(16),
                child: Icon(
                  _playing ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                  size: 48,
                ),
              ),
            ),
            const SizedBox(height: 24),
            _MediaProgressBar(
              position: _position,
              duration: _duration,
              onSeek: _player.seek,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(_position),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                Text(
                  _formatDuration(_duration),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

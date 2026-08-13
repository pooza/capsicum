import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../../service/sticker_source.dart';
import '../../util/exception_scrub.dart';
import '../util/image_overlay_geometry.dart';

/// 添付画像に重ねる 1 レイヤの共通部分 (#576 / #883)。
///
/// 位置は画像内の正規化中心座標 (0..1)、大きさは画像高さに対する比率で保持
/// する。こうすることで編集画面 (画像を画面に fit 表示) と書き出し (原寸
/// Canvas) で同じ見た目を再現できる (WYSIWYG)。回転角も同じ性質を持つので、
/// 入れるならここに足せる (#946)。
sealed class _OverlayItem {
  _OverlayItem({required this.sizeFrac});

  double nx = 0.5;
  double ny = 0.5;

  /// 画像高さに対する比率。文字ならフォントサイズ、スタンプなら描画高さ。
  double sizeFrac;
}

/// 文字 / Unicode 絵文字のレイヤ (#576)。
class _TextOverlayItem extends _OverlayItem {
  _TextOverlayItem({required this.text}) : super(sizeFrac: 0.08);

  String text;
  Color color = Colors.white;
}

/// カスタム絵文字を素材にした画像スタンプのレイヤ (#883)。
///
/// [image] は表示と書き出しで**同じ実体を共有する**。別々にデコードすると
/// アニメーション絵文字でフレームがずれうるうえ、二重に取得することになる。
class _StickerOverlayItem extends _OverlayItem {
  _StickerOverlayItem({required this.image, required this.shortcode})
    : super(sizeFrac: 0.2);

  final ui.Image image;

  /// 素材にしたカスタム絵文字のショートコード。選択枠の tooltip に使う。
  final String shortcode;

  /// 元画像の縦横比。カスタム絵文字は横長のものが珍しくないので、高さ基準の
  /// [sizeFrac] から幅を復元するのに要る。
  double get aspect => image.width / image.height;
}

/// 添付画像に文字 / Unicode 絵文字 (#576) とカスタム絵文字スタンプ (#883) を
/// 重ねて PNG に書き出すエディタ。
///
/// mixi2 風のメモ書き・ミーム的キャプション用途。フィルタ / 落書き / レイヤ履歴 /
/// ベクター編集は対象外 (#568 の方針を継承)。入力バイト列をメモリ上で合成し、
/// 結果の PNG バイト列を [Navigator.pop] で返す（キャンセル時は null）。
/// トリミング ([ImageCropScreen]) と同じく純 Flutter 実装で全プラットフォーム
/// 動作する。
class ImageOverlayScreen extends ConsumerStatefulWidget {
  const ImageOverlayScreen({super.key, required this.imageData, this.title});

  /// 対象の元画像バイト列。
  final Uint8List imageData;

  /// AppBar に表示するタイトル。未指定時は既定文言。
  final String? title;

  @override
  ConsumerState<ImageOverlayScreen> createState() => _ImageOverlayScreenState();
}

class _ImageOverlayScreenState extends ConsumerState<ImageOverlayScreen> {
  /// 表示用に PNG 正規化した画像。デコード完了まで null。
  Uint8List? _image;

  /// 原寸の画像サイズ（書き出し座標計算に使う）。
  Size? _imageSize;

  final List<_OverlayItem> _items = [];
  int? _selected;

  /// 書き出し中は再押下・離脱を防ぐ。
  bool _rendering = false;

  /// スタンプ素材の取得中。連打で同じ絵文字が二重に載るのを防ぐ。
  bool _loadingSticker = false;

  static const _colorOptions = <Color>[
    Colors.white,
    Colors.black,
    Colors.red,
    Colors.amber,
    Colors.lightBlue,
    Colors.greenAccent,
  ];

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void dispose() {
    for (final item in _items) {
      if (item is _StickerOverlayItem) item.image.dispose();
    }
    super.dispose();
  }

  /// 入力バイト列をネイティブコーデックでデコードし、原寸サイズと表示用 PNG を
  /// 得る。デコードできない画像は対象外として呼び出し元へ戻す。
  Future<void> _decode() async {
    // 解放は try/finally に寄せる (#953-4)。成功パスの一直線上に dispose を
    // 置くと、`toByteData` が投げたときに原寸画像ぶんのネイティブメモリが
    // そのまま残る。
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(widget.imageData);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final size = Size(image.width.toDouble(), image.height.toDouble());
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw StateError('Failed to encode normalized PNG');
      }
      if (!mounted) return;
      setState(() {
        _image = data.buffer.asUint8List();
        _imageSize = size;
      });
    } catch (e, st) {
      await Sentry.captureException(scrubException(e), stackTrace: st);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('この画像は編集できませんでした')));
      Navigator.of(context).pop();
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  /// テキスト入力ダイアログ。[initial] を渡すと既存レイヤの編集。
  Future<String?> _promptText({String initial = ''}) {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => _TextPromptDialog(initial: initial),
    );
  }

  Future<void> _addTextItem() async {
    final text = await _promptText();
    if (!mounted) return;
    if (text == null || text.trim().isEmpty) return;
    setState(() {
      _items.add(_TextOverlayItem(text: text));
      _selected = _items.length - 1;
    });
  }

  /// カスタム絵文字を選ばせ、その画像をスタンプレイヤとして追加する (#883)。
  Future<void> _addStickerItem() async {
    if (_loadingSticker) return;
    final source = ref.read(stickerSourceProvider);
    final emoji = await source.pick(context: context, ref: ref);
    if (emoji == null || !mounted) return;

    setState(() => _loadingSticker = true);
    try {
      final image = await source.load(emoji.url);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _items.add(
          _StickerOverlayItem(image: image, shortcode: emoji.shortcode),
        );
        _selected = _items.length - 1;
        _loadingSticker = false;
      });
    } catch (e, st) {
      // ⚠ ここには **リモート URL 由来の DioException** が来る。dio の版差で
      // uri が message に載りうるので必ず scrub を通す (#953-4)。
      await Sentry.captureException(scrubException(e), stackTrace: st);
      if (!mounted) return;
      setState(() => _loadingSticker = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('スタンプを読み込めませんでした')));
    }
  }

  Future<void> _editSelected() async {
    final index = _selected;
    if (index == null) return;
    final item = _items[index];
    // 編集できるのは文字レイヤだけ。スタンプは貼り直しで差し替える。
    if (item is! _TextOverlayItem) return;
    final text = await _promptText(initial: item.text);
    if (!mounted) return;
    if (text == null) return;
    if (text.trim().isEmpty) {
      _deleteSelected();
      return;
    }
    setState(() => item.text = text);
  }

  void _deleteSelected() {
    final index = _selected;
    if (index == null) return;
    final removed = _items[index];
    setState(() {
      _items.removeAt(index);
      _selected = null;
    });
    if (removed is _StickerOverlayItem) {
      // ツリーから外れるのは次フレーム。同フレーム内で dispose すると、まだ
      // 描画中の RawImage が破棄済み画像を掴んで落ちる。
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => removed.image.dispose(),
      );
    }
  }

  /// テキストの可読性のため、明度に応じて反対色の擬似アウトライン (4 方向の
  /// shadow) を付与する。shadow の offset は fontSize に比例させるので、編集画面と
  /// 書き出しで同じ見た目になる。
  TextStyle _textStyle(Color color, double fontSize) {
    final outline = color.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;
    final d = fontSize / 22;
    return TextStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: FontWeight.bold,
      height: 1.1,
      shadows: [
        Shadow(offset: Offset(-d, -d), color: outline),
        Shadow(offset: Offset(d, -d), color: outline),
        Shadow(offset: Offset(d, d), color: outline),
        Shadow(offset: Offset(-d, d), color: outline),
      ],
    );
  }

  Future<void> _render() async {
    final size = _imageSize;
    if (size == null || _rendering) return;
    setState(() => _rendering = true);
    // 解放は try/finally に寄せる (#953-4)。dispose が成功パスの一直線上に
    // しか無いと、書き出し失敗を繰り返すたびに原寸画像ぶんのネイティブメモリが
    // 積み上がる。
    ui.Codec? codec;
    ui.Image? src;
    ui.Picture? picture;
    ui.Image? out;
    try {
      codec = await ui.instantiateImageCodec(widget.imageData);
      final frame = await codec.getNextFrame();
      src = frame.image;
      // PopScope で塞いでいるが、await 明けに State が生きていることを
      // 描画前にもう一度確かめる（プログラム的な pop など経路は他にもある）。
      // ここを抜けた後は破棄済みの `item.image` を掴みうる。
      if (!mounted) return;
      final w = size.width;
      final h = size.height;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImage(src, Offset.zero, Paint());

      for (final item in _items) {
        switch (item) {
          case _TextOverlayItem():
            _paintText(canvas, item, w, h);
          case _StickerOverlayItem():
            _paintSticker(canvas, item, w, h);
        }
      }

      picture = recorder.endRecording();
      out = await picture.toImage(w.round(), h.round());
      final data = await out.toByteData(format: ui.ImageByteFormat.png);

      if (data == null) {
        throw StateError('Failed to encode composited PNG');
      }
      if (!mounted) return;
      Navigator.of(context).pop(data.buffer.asUint8List());
    } catch (e, st) {
      await Sentry.captureException(scrubException(e), stackTrace: st);
      if (!mounted) return;
      setState(() => _rendering = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('画像の書き出しに失敗しました')));
    } finally {
      out?.dispose();
      picture?.dispose();
      src?.dispose();
      codec?.dispose();
    }
  }

  void _paintText(Canvas canvas, _TextOverlayItem item, double w, double h) {
    if (item.text.trim().isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(
        text: item.text,
        style: _textStyle(item.color, item.sizeFrac * h),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );
    // 画像幅の 96% を上限に折り返す。
    painter.layout(maxWidth: w * 0.96);
    final center = Offset(item.nx * w, item.ny * h);
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  void _paintSticker(
    Canvas canvas,
    _StickerOverlayItem item,
    double w,
    double h,
  ) {
    final dst = stickerOverlayRect(
      center: Offset(item.nx * w, item.ny * h),
      sizeFrac: item.sizeFrac,
      aspect: item.aspect,
      referenceHeight: h,
    );
    canvas.drawImageRect(
      item.image,
      Rect.fromLTWH(
        0,
        0,
        item.image.width.toDouble(),
        item.image.height.toDouble(),
      ),
      dst,
      Paint()..filterQuality = FilterQuality.high,
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final size = _imageSize;
    // 書き出し中は離脱させない。`_render` は codec のデコードを await した後に
    // `_items` を走査して `item.image` を描画するので、await 中に pop されると
    // `dispose` が破棄した ui.Image を掴む（release ではネイティブハンドルの
    // use-after-free）。「完了」ボタンを消すだけでは戻る矢印・Android の戻る・
    // iOS のスワイプバックが素通りする。
    return PopScope(canPop: !_rendering, child: _buildScaffold(image, size));
  }

  Widget _buildScaffold(Uint8List? image, Size? size) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title ?? '文字・スタンプを入れる'),
        actions: [
          if (_rendering)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (image != null)
            TextButton(onPressed: _render, child: const Text('完了')),
        ],
      ),
      body: image == null || size == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(child: _buildCanvas(image, size)),
                _buildToolbar(),
              ],
            ),
    );
  }

  Widget _buildCanvas(Uint8List image, Size size) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cw = constraints.maxWidth;
        final ch = constraints.maxHeight;
        final scale = (cw / size.width) < (ch / size.height)
            ? cw / size.width
            : ch / size.height;
        final dispW = size.width * scale;
        final dispH = size.height * scale;
        final dx = (cw - dispW) / 2;
        final dy = (ch - dispH) / 2;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 画像の余白タップで選択解除。
          onTap: () => setState(() => _selected = null),
          child: Stack(
            children: [
              // レイヤは画像と同じ矩形の中に置き、はみ出しは ClipRect で切る。
              // 書き出しは原寸 Canvas の外へ描いた分が捨てられるので、プレビュー
              // 側も同じ位置で切らないと「余白にはみ出した部分が書き出すと消える」
              // ズレが出る (#883)。レイヤの座標も画像内相対にできる。
              Positioned(
                left: dx,
                top: dy,
                width: dispW,
                height: dispH,
                child: ClipRect(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Image.memory(image, fit: BoxFit.fill),
                      ),
                      for (var i = 0; i < _items.length; i++)
                        _buildItemWidget(i, dispW, dispH),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildItemWidget(int index, double dispW, double dispH) {
    final item = _items[index];
    final selected = _selected == index;
    return Positioned(
      left: item.nx * dispW,
      top: item.ny * dispH,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _selected = index),
          onPanUpdate: (details) {
            setState(() {
              item.nx = (item.nx + details.delta.dx / dispW).clamp(0.0, 1.0);
              item.ny = (item.ny + details.delta.dy / dispH).clamp(0.0, 1.0);
              _selected = index;
            });
          },
          child: Container(
            // 折り返し幅の上限は**文字レイヤ専用**。書き出し側の
            // `painter.layout(maxWidth: w * 0.96)` と対になっている。スタンプに
            // 掛けると RawImage が縮んでプレビューだけ小さくなり、書き出し
            // (drawImageRect は制約を受けない) と食い違う。
            constraints: item is _TextOverlayItem
                ? BoxConstraints(maxWidth: dispW * 0.96)
                : null,
            decoration: selected
                ? BoxDecoration(
                    border: Border.all(color: Colors.white70),
                    borderRadius: BorderRadius.circular(4),
                  )
                : null,
            padding: const EdgeInsets.all(2),
            child: switch (item) {
              _TextOverlayItem() => Text(
                item.text,
                textAlign: TextAlign.center,
                style: _textStyle(item.color, item.sizeFrac * dispH),
              ),
              _StickerOverlayItem() => _buildStickerPreview(item, dispH),
            },
          ),
        ),
      ),
    );
  }

  Widget _buildStickerPreview(_StickerOverlayItem item, double dispH) {
    // 書き出しとまったく同じ式で寸法を出す。ここが割れると WYSIWYG が崩れる。
    final rect = stickerOverlayRect(
      center: Offset.zero,
      sizeFrac: item.sizeFrac,
      aspect: item.aspect,
      referenceHeight: dispH,
    );
    return Tooltip(
      message: ':${item.shortcode}:',
      child: RawImage(
        image: item.image,
        width: rect.width,
        height: rect.height,
        fit: BoxFit.fill,
        filterQuality: FilterQuality.high,
      ),
    );
  }

  Widget _buildToolbar() {
    final index = _selected;
    final item = index != null ? _items[index] : null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (item != null) ...[
              // 色は文字レイヤ専用。スタンプは元画像の色をそのまま使う。
              if (item is _TextOverlayItem) _buildColorRow(item),
              _buildSizeRow(item),
            ],
            _buildAddRow(),
          ],
        ),
      ),
    );
  }

  Widget _buildColorRow(_TextOverlayItem item) {
    return Row(
      children: [
        for (final c in _colorOptions)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => setState(() => item.color = c),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: item.color == c
                        ? Colors.lightBlueAccent
                        : Colors.white30,
                    width: item.color == c ? 3 : 1,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSizeRow(_OverlayItem item) {
    final isText = item is _TextOverlayItem;
    return Row(
      children: [
        Icon(
          isText ? Icons.text_fields : Icons.emoji_emotions_outlined,
          color: Colors.white,
          size: 20,
        ),
        Expanded(
          child: Slider(
            value: item.sizeFrac,
            // スタンプは絵として見せるので、文字より大きく引き伸ばせる。
            min: 0.03,
            max: isText ? 0.25 : 0.8,
            onChanged: (v) => setState(() => item.sizeFrac = v),
          ),
        ),
        if (isText)
          IconButton(
            icon: const Icon(Icons.edit, color: Colors.white),
            tooltip: 'テキストを編集',
            onPressed: _editSelected,
          ),
        IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.white),
          tooltip: '削除',
          onPressed: _deleteSelected,
        ),
      ],
    );
  }

  Widget _buildAddRow() {
    // `Row` ではなく `Wrap`。v1.53 までは `TextButton.icon` 1 個だったところに
    // #883 で「スタンプを追加」を足したが、`Row` のままだったので狭幅で
    // RenderFlex overflow していた (#953-3)。widget test の実測で **320 論理 px
    // 幅で 9.4px、テキストスケール 1.15 で 32px、1.3 で 54px**、375px でも 1.35
    // 倍以上で破綻する。該当は iPhone SE(1st) / iPod touch、iOS の Display Zoom、
    // Android の「表示サイズ」拡大。
    //
    // `Expanded` / `Flexible` ではなく `Wrap` を選んだのは、ラベルを省略記号で
    // 削るより 2 行に折り返す方がボタンの意味が残るため。入る幅では 1 行のまま
    // なので通常時の見た目は変わらない。
    return Wrap(
      children: [
        TextButton.icon(
          onPressed: _addTextItem,
          icon: const Icon(Icons.add),
          label: const Text('テキストを追加'),
        ),
        TextButton.icon(
          onPressed: _loadingSticker ? null : _addStickerItem,
          icon: _loadingSticker
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add_reaction_outlined),
          label: const Text('スタンプを追加'),
        ),
      ],
    );
  }
}

/// テキストレイヤの入力ダイアログ (#576)。
///
/// [TextEditingController] を**ダイアログ自身に所有させる**のが肝 (#947)。
/// 呼び出し側で `showDialog` の解決直後に dispose すると、まだ退場アニメーション
/// 中で `TextField` が再構築されるため use-after-dispose になる（#953-4 のリーク
/// 修正がこの形だった）。State の dispose はルートが実際に外れてから呼ばれるので、
/// リークもせず早すぎもしない。
class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({required this.initial});

  final String initial;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('テキスト / 絵文字'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: null,
        decoration: const InputDecoration(
          hintText: '重ねる文字や絵文字を入力',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

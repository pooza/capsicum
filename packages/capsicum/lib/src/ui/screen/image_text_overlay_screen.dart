import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// 添付画像に重ねる 1 つのテキスト / 絵文字レイヤ (#576)。
///
/// 位置は画像内の正規化中心座標 (0..1)、フォントサイズは画像高さに対する比率で
/// 保持する。こうすることで編集画面 (画像を画面に fit 表示) と書き出し
/// (原寸 Canvas) で同じ見た目を再現できる (WYSIWYG)。
class _TextOverlayItem {
  _TextOverlayItem({required this.text});

  String text;
  double nx = 0.5;
  double ny = 0.5;
  Color color = Colors.white;
  double sizeFrac = 0.08;
}

/// 添付画像に文字 / Unicode 絵文字を重ねて PNG に書き出すエディタ (#576)。
///
/// mixi2 風のメモ書き・ミーム的キャプション用途。フィルタ / スタンプ / 落書き /
/// レイヤ履歴 / ベクター編集は対象外 (#568 の方針を継承)。入力バイト列をメモリ
/// 上で合成し、結果の PNG バイト列を [Navigator.pop] で返す（キャンセル時は
/// null）。トリミング ([ImageCropScreen]) と同じく純 Flutter 実装で全
/// プラットフォーム動作する。
class ImageTextOverlayScreen extends StatefulWidget {
  const ImageTextOverlayScreen({
    super.key,
    required this.imageData,
    this.title,
  });

  /// 対象の元画像バイト列。
  final Uint8List imageData;

  /// AppBar に表示するタイトル。未指定時は既定文言。
  final String? title;

  @override
  State<ImageTextOverlayScreen> createState() => _ImageTextOverlayScreenState();
}

class _ImageTextOverlayScreenState extends State<ImageTextOverlayScreen> {
  /// 表示用に PNG 正規化した画像。デコード完了まで null。
  Uint8List? _image;

  /// 原寸の画像サイズ（書き出し座標計算に使う）。
  Size? _imageSize;

  final List<_TextOverlayItem> _items = [];
  int? _selected;

  /// 書き出し中は再押下・離脱を防ぐ。
  bool _rendering = false;

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

  /// 入力バイト列をネイティブコーデックでデコードし、原寸サイズと表示用 PNG を
  /// 得る。デコードできない画像は対象外として呼び出し元へ戻す。
  Future<void> _decode() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.imageData);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final size = Size(image.width.toDouble(), image.height.toDouble());
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      codec.dispose();
      if (data == null) {
        throw StateError('Failed to encode normalized PNG');
      }
      if (!mounted) return;
      setState(() {
        _image = data.buffer.asUint8List();
        _imageSize = size;
      });
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('この画像は編集できませんでした')));
      Navigator.of(context).pop();
    }
  }

  /// テキスト入力ダイアログ。[initial] を渡すと既存レイヤの編集。
  Future<String?> _promptText({String initial = ''}) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('テキスト / 絵文字'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: null,
          decoration: const InputDecoration(
            hintText: '重ねる文字や絵文字を入力',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _addItem() async {
    final text = await _promptText();
    if (!mounted) return;
    if (text == null || text.trim().isEmpty) return;
    setState(() {
      _items.add(_TextOverlayItem(text: text));
      _selected = _items.length - 1;
    });
  }

  Future<void> _editSelected() async {
    final index = _selected;
    if (index == null) return;
    final text = await _promptText(initial: _items[index].text);
    if (!mounted) return;
    if (text == null) return;
    if (text.trim().isEmpty) {
      setState(() {
        _items.removeAt(index);
        _selected = null;
      });
      return;
    }
    setState(() => _items[index].text = text);
  }

  void _deleteSelected() {
    final index = _selected;
    if (index == null) return;
    setState(() {
      _items.removeAt(index);
      _selected = null;
    });
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
    try {
      final codec = await ui.instantiateImageCodec(widget.imageData);
      final frame = await codec.getNextFrame();
      final src = frame.image;
      final w = size.width;
      final h = size.height;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImage(src, Offset.zero, Paint());

      for (final item in _items) {
        if (item.text.trim().isEmpty) continue;
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

      final picture = recorder.endRecording();
      final out = await picture.toImage(w.round(), h.round());
      final data = await out.toByteData(format: ui.ImageByteFormat.png);

      src.dispose();
      codec.dispose();
      picture.dispose();
      out.dispose();

      if (data == null) {
        throw StateError('Failed to encode composited PNG');
      }
      if (!mounted) return;
      Navigator.of(context).pop(data.buffer.asUint8List());
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      if (!mounted) return;
      setState(() => _rendering = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('画像の書き出しに失敗しました')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final size = _imageSize;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title ?? '文字を入れる'),
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
              Positioned(
                left: dx,
                top: dy,
                width: dispW,
                height: dispH,
                child: Image.memory(image, fit: BoxFit.fill),
              ),
              for (var i = 0; i < _items.length; i++)
                _buildItemWidget(i, dx, dy, dispW, dispH),
            ],
          ),
        );
      },
    );
  }

  Widget _buildItemWidget(
    int index,
    double dx,
    double dy,
    double dispW,
    double dispH,
  ) {
    final item = _items[index];
    final selected = _selected == index;
    final fontSize = item.sizeFrac * dispH;
    return Positioned(
      left: dx + item.nx * dispW,
      top: dy + item.ny * dispH,
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
            constraints: BoxConstraints(maxWidth: dispW * 0.96),
            decoration: selected
                ? BoxDecoration(
                    border: Border.all(color: Colors.white70),
                    borderRadius: BorderRadius.circular(4),
                  )
                : null,
            padding: const EdgeInsets.all(2),
            child: Text(
              item.text,
              textAlign: TextAlign.center,
              style: _textStyle(item.color, fontSize),
            ),
          ),
        ),
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
              Row(
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
              ),
              Row(
                children: [
                  const Icon(Icons.text_fields, color: Colors.white, size: 20),
                  Expanded(
                    child: Slider(
                      value: item.sizeFrac,
                      min: 0.03,
                      max: 0.25,
                      onChanged: (v) => setState(() => item.sizeFrac = v),
                    ),
                  ),
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
              ),
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addItem,
                icon: const Icon(Icons.add),
                label: const Text('テキストを追加'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

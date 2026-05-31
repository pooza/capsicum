import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// 添付画像をトリミングする全画面エディタ (#577)。
///
/// crop_your_image は platform channel を持たない純 Flutter 実装のため、
/// image_cropper 非対応の macOS / Windows / Linux でも動作する。入力の
/// バイト列をメモリ上で処理し、トリミング結果のバイト列を [Navigator.pop] で
/// 呼び出し元に返す（キャンセル時は null）。モバイルのトリミング (#568) とは
/// 別経路で、本画面はデスクトップの添付画像から呼ばれる。
class ImageCropScreen extends StatefulWidget {
  const ImageCropScreen({super.key, required this.imageData, this.title});

  /// トリミング対象の元画像バイト列。
  final Uint8List imageData;

  /// AppBar に表示するタイトル。未指定時は既定文言。
  final String? title;

  @override
  State<ImageCropScreen> createState() => _ImageCropScreenState();
}

class _ImageCropScreenState extends State<ImageCropScreen> {
  final _controller = CropController();

  /// crop_your_image のデコーダ (image パッケージ) は HEIC や一部 WebP 等を
  /// 扱えず、サムネイルは出るのにトリミング画面だけ真っ黒になる。Flutter
  /// ネイティブのコーデックで一度デコードして PNG に正規化し、表示できる形式は
  /// すべてトリミング可能にする (#577)。変換完了まで null。
  Uint8List? _normalizedImage;

  /// 完了押下からコールバック到達までの間、再押下と離脱を防ぐ。
  bool _cropping = false;

  @override
  void initState() {
    super.initState();
    _normalizeImage();
  }

  /// 入力バイト列をネイティブコーデックでデコードし PNG へ正規化する。
  /// デコードできない (= ネイティブでも表示不能な) 画像はトリミング不可として
  /// 呼び出し元へ戻す。
  Future<void> _normalizeImage() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.imageData);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      if (data == null) {
        throw StateError('Failed to encode normalized PNG');
      }
      if (!mounted) return;
      setState(() => _normalizedImage = data.buffer.asUint8List());
    } catch (e, st) {
      await Sentry.captureException(e, stackTrace: st);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('この画像はトリミングできませんでした')));
      Navigator.of(context).pop();
    }
  }

  /// 現在の固定アスペクト比。null は自由比率。
  double? _aspectRatio;

  /// 表示順を保つためラベルと比率を List で持つ。null = フリー。
  static const _aspectOptions = <(String, double?)>[
    ('フリー', null),
    ('1:1', 1.0),
    ('4:3', 4 / 3),
    ('3:4', 3 / 4),
    ('16:9', 16 / 9),
    ('9:16', 9 / 16),
  ];

  void _selectAspect(double? ratio) {
    setState(() => _aspectRatio = ratio);
    _controller.aspectRatio = ratio;
  }

  void _startCrop() {
    setState(() => _cropping = true);
    _controller.crop();
  }

  void _onCropped(CropResult result) {
    if (!mounted) return;
    switch (result) {
      case CropSuccess(:final croppedImage):
        Navigator.of(context).pop(croppedImage);
      case CropFailure():
        setState(() => _cropping = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('トリミングに失敗しました')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _normalizedImage;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title ?? '画像をトリミング'),
        actions: [
          if (_cropping)
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
            TextButton(onPressed: _startCrop, child: const Text('完了')),
        ],
      ),
      body: image == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: Crop(
                    image: image,
                    controller: _controller,
                    aspectRatio: _aspectRatio,
                    baseColor: Colors.black,
                    maskColor: Colors.black.withValues(alpha: 0.6),
                    cornerDotBuilder: (size, edgeAlignment) =>
                        const DotControl(color: Colors.white),
                    interactive: true,
                    progressIndicator: const CircularProgressIndicator(),
                    onCropped: _onCropped,
                  ),
                ),
                SafeArea(
                  top: false,
                  child: SizedBox(
                    height: 56,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: _aspectOptions.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final (label, ratio) = _aspectOptions[index];
                        return Center(
                          child: ChoiceChip(
                            label: Text(label),
                            selected: _aspectRatio == ratio,
                            onSelected: _cropping
                                ? null
                                : (_) => _selectAspect(ratio),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

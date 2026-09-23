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
/// Canvas) で同じ見た目を再現できる (WYSIWYG)。
sealed class _OverlayItem {
  _OverlayItem({required this.id, required this.sizeFrac});

  /// レイヤの同一性 (#1125)。画面の中で一意・不変。
  ///
  /// ⚠⚠ **選択は添字ではなくこれで持つ。**並べ替え・非表示・ロック（#884-B〜D）を
  /// 入れると添字は動くので、添字で持つと並べ替えた瞬間に選択が別のレイヤを指す。
  final int id;

  double nx = 0.5;
  double ny = 0.5;

  /// 画像高さに対する比率。文字ならフォントサイズ、スタンプなら描画高さ。
  double sizeFrac;

  /// 中心まわりの回転角（ラジアン・時計回り）(#946)。
  ///
  /// [nx] / [ny] / [sizeFrac] と同じくスケール不変なので、編集画面と書き出しで
  /// **同じ値をそのまま使える**。⚠ ただし回す中心は両方とも「レイヤの中心」で
  /// なければならない。プレビューは [Transform.rotate]（既定で中心まわり）、
  /// 書き出しは `translate(中心) → rotate → 中心原点で描画` で揃えている。
  double angle = 0;

  /// レイヤ一覧に出す見出し (#1126)。サムネだけでは小さすぎて見分けられない。
  String get label;

  /// レイヤ一覧に出す種別アイコン (#1126)。
  IconData get icon;
}

/// 文字 / Unicode 絵文字のレイヤ (#576)。
class _TextOverlayItem extends _OverlayItem {
  _TextOverlayItem({required super.id, required this.text})
    : super(sizeFrac: kOverlayDefaultTextSizeFrac);

  String text;
  Color color = Colors.white;

  @override
  String get label => text;

  @override
  IconData get icon => Icons.text_fields;
}

/// カスタム絵文字を素材にした画像スタンプのレイヤ (#883)。
///
/// [image] は表示と書き出しで**同じ実体を共有する**。別々にデコードすると
/// アニメーション絵文字でフレームがずれうるうえ、二重に取得することになる。
class _StickerOverlayItem extends _OverlayItem {
  _StickerOverlayItem({
    required super.id,
    required this.image,
    required this.shortcode,
  }) : super(sizeFrac: kOverlayDefaultStickerSizeFrac);

  final ui.Image image;

  /// 素材にしたカスタム絵文字のショートコード。選択枠の tooltip に使う。
  final String shortcode;

  /// 元画像の縦横比。カスタム絵文字は横長のものが珍しくないので、高さ基準の
  /// [sizeFrac] から幅を復元するのに要る。
  double get aspect => image.width / image.height;

  @override
  String get label => ':$shortcode:';

  @override
  IconData get icon => Icons.emoji_emotions_outlined;
}

/// 削除したが、まだ取り消せるレイヤ (#1126 / #1131)。
///
/// ⚠⚠ **スタンプの `ui.Image` はここに掴まれている間は解放しない。**「元に戻す」で
/// 戻したレイヤが描けないと取り消しの意味が無いため。代わりに解放の期限を
/// [kOverlayUndoWindow]（SnackBar が閉じるまで）で切り、閉じたら必ず解放する。
class _PendingDeletion {
  _PendingDeletion({required this.item, required this.index});

  final _OverlayItem item;

  /// 消す前の重ね順の位置。取り消しは**同じ高さへ戻す**（末尾へ積み直すと、
  /// 背面にあったレイヤが最前面になって画が変わる）。
  final int index;
}

/// 添付画像に文字 / Unicode 絵文字 (#576) とカスタム絵文字スタンプ (#883) を
/// 重ねて PNG に書き出すエディタ。
///
/// mixi2 風のメモ書き・ミーム的キャプション用途。フィルタ / 落書き / 操作履歴
/// （元に戻す）/ ベクター編集は対象外 (#568 の方針を継承)。⚠ **レイヤの管理
/// （重ね順・表示/非表示・ロック・不透明度・再編集）は #884 で対象に入れた**
/// ——以前はここに「レイヤ履歴は対象外」と書いていたが、#884 はその一文の
/// 再交渉にあたる。入力バイト列をメモリ上で合成し、
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

  /// 重ね順（先頭が最背面）。
  final List<_OverlayItem> _items = [];

  /// 選択中のレイヤの ID (#1125)。⚠ 添字で持たない（[_OverlayItem.id]）。
  int? _selectedId;

  /// 次に足すレイヤの ID。画面の中で使い回さない。
  int _nextId = 0;

  /// 削除したが取り消せる状態のレイヤ (#1126)。⚠ **ここに残っている間は
  /// `ui.Image` を解放しない。**解放は [_finalizeDeletion] だけが行う。
  final List<_PendingDeletion> _pendingDeletions = [];

  /// レイヤ一覧を開いているか (#1126)。
  ///
  /// ⚠ **既定は閉じた状態にする。**一覧は広い幅ならキャンバスの横を 280px、
  /// 狭い幅なら下を 176px 取る。既定で開くと**何もしていないのに編集面が狭くなる**
  /// ので、開くかどうかは常に利用者に決めさせる。幅が決めるのは**置き場所だけ**。
  bool _layersOpen = false;

  _OverlayItem? get _selectedItem {
    for (final item in _items) {
      if (item.id == _selectedId) return item;
    }
    return null;
  }

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
    // ⚠⚠ **取り消し待ちも必ず畳む。**`_items` から外れているので上のループには
    // 掛からず、SnackBar の `closed` は画面が消えた後に解決するとは限らない
    // （ScaffoldMessenger ごと外れると来ない）。ここで畳まないと、削除して
    // すぐ閉じたぶんだけスタンプの原寸画像が漏れる (#1126)。
    for (final pending in _pendingDeletions.toList()) {
      _finalizeDeletion(pending);
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
      final item = _TextOverlayItem(id: _nextId++, text: text);
      _items.add(item);
      _selectedId = item.id;
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
        final item = _StickerOverlayItem(
          id: _nextId++,
          image: image,
          shortcode: emoji.shortcode,
        );
        _items.add(item);
        _selectedId = item.id;
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
    final item = _selectedItem;
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
    final removed = _selectedItem;
    if (removed != null) _deleteLayer(removed);
  }

  /// レイヤを 1 枚消し、取り消しの導線を出す (#1126 / #1131)。
  ///
  /// ⚠⚠ **汎用の Undo / Redo は作らない。**#884 で入る操作のうち**不可逆なのは削除だけ**
  /// で、並べ替え・表示/非表示・不透明度はいずれも同じ操作で元へ戻せる。一覧が
  /// できてまとめて消しやすくなったぶんだけ、削除にだけ取り消しを付ける。
  void _deleteLayer(_OverlayItem removed) {
    final index = _items.indexOf(removed);
    if (index < 0) return;
    setState(() {
      _items.removeAt(index);
      if (_selectedId == removed.id) _selectedId = null;
    });

    final pending = _PendingDeletion(item: removed, index: index);
    _pendingDeletions.add(pending);

    // 連続して消したときは、前の SnackBar を先に閉じて取り消し先を 1 つに保つ。
    // 閉じた側は `closed` が解決して確定（＝解放）へ進む。
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    messenger
        .showSnackBar(
          SnackBar(
            duration: kOverlayUndoWindow,
            // ⚠⚠ **`persist: false` を明示する。**Flutter の既定は
            // `persist = persist ?? action != null` で、**アクション付きの
            // SnackBar は時間で閉じない**。既定のままだと `duration` が効かず、
            // 取り消し待ちのスタンプの原寸画像が**上限なしで**ネイティブ側に
            // 残り続ける（画面を閉じるまで解放されない）。
            persist: false,
            content: Text('「${_shortLabel(removed)}」を削除しました'),
            action: SnackBarAction(
              label: '元に戻す',
              onPressed: () => _restoreDeletion(pending),
            ),
          ),
        )
        .closed
        .then((_) => _finalizeDeletion(pending));
  }

  /// 取り消しの期限切れ（または画面の終了）。⚠ **解放はここだけが行う。**
  ///
  /// 復帰済み・確定済みのものを二度解放しないよう、**一覧から取り除けたときだけ**
  /// 進む（`closed` の解決と「元に戻す」の押下は順序が保証されない）。
  void _finalizeDeletion(_PendingDeletion pending) {
    if (!_pendingDeletions.remove(pending)) return;
    final item = pending.item;
    // 削除からここまでに最低でも SnackBar 1 本ぶんのフレームが流れているので、
    // #953-4 のように次フレームまで待つ必要はない（まだ描いている RawImage は
    // もう無い）。画面終了時はツリーごと外れた後なので同じ。
    if (item is _StickerOverlayItem) item.image.dispose();
  }

  void _restoreDeletion(_PendingDeletion pending) {
    if (!mounted) return;
    if (!_pendingDeletions.remove(pending)) return;
    setState(() {
      _items.insert(pending.index.clamp(0, _items.length), pending.item);
      _selectedId = pending.item.id;
    });
  }

  /// SnackBar に出す短い見出し。長い本文をそのまま出すと行が溢れる。
  String _shortLabel(_OverlayItem item) {
    final label = item.label.replaceAll('\n', ' ').trim();
    if (label.isEmpty) return 'レイヤー';
    return label.characters.length <= 12
        ? label
        : '${label.characters.take(12).toString()}…';
  }

  /// レイヤ一覧に並べる順。**最前面が先頭**（画像編集の慣習）。
  ///
  /// ⚠ [_items] は**末尾が最前面**（プレビューも書き出しも先頭から順に重ねて
  /// いく）。一覧だけ逆順で見せるので、並べ替えは一覧の順で済ませてから
  /// 逆にして戻す。添字の対応を手で書くより間違えにくい。
  List<_OverlayItem> get _layersFrontFirst => _items.reversed.toList();

  /// レイヤ一覧（最前面が先頭）の中での並べ替え (#1126)。
  void _reorderLayers(int oldIndex, int newIndex) {
    setState(() {
      final reordered = reorderOverlayLayers(
        _layersFrontFirst,
        oldIndex,
        newIndex,
      );
      _items
        ..clear()
        ..addAll(reordered.reversed);
    });
  }

  /// テキストの可読性のため、明度に応じて反対色の擬似アウトライン (4 方向の
  /// shadow) を付与する。shadow の offset は fontSize に比例させるので、編集画面と
  /// 書き出しで同じ見た目になる。
  TextStyle _textStyle(Color color, double fontSize) {
    final outline = color.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;
    final d = fontSize / kOverlayOutlineWidthDivisor;
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
    painter.layout(maxWidth: w * kOverlayTextWrapFraction);
    _paintRotated(canvas, item, w, h, () {
      // 回転の中心を原点に持ってきてあるので、ここは中心原点で描く。
      painter.paint(canvas, -Offset(painter.width / 2, painter.height / 2));
    });
  }

  void _paintSticker(
    Canvas canvas,
    _StickerOverlayItem item,
    double w,
    double h,
  ) {
    // 中心を原点にした矩形。位置は _paintRotated の translate が担う。
    final dst = stickerOverlayRect(
      center: Offset.zero,
      sizeFrac: item.sizeFrac,
      aspect: item.aspect,
      referenceHeight: h,
    );
    _paintRotated(canvas, item, w, h, () {
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
    });
  }

  /// レイヤの中心を原点に据え、[_OverlayItem.angle] だけ回した状態で [paint] を
  /// 呼ぶ (#946)。
  ///
  /// ⚠ **回す中心はプレビュー側（[Transform.rotate] の既定 = 中心）と揃える。**
  /// 左上まわりに回すと、角度を動かした瞬間にレイヤが画面上を移動して見え、
  /// 編集画面と書き出しでも位置が食い違う。
  void _paintRotated(
    Canvas canvas,
    _OverlayItem item,
    double w,
    double h,
    VoidCallback paint,
  ) {
    final center = Offset(item.nx * w, item.ny * h);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(item.angle);
    paint();
    canvas.restore();
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
    // 一覧をキャンバスの横に置ける幅か。⚠ 分岐軸はプラットフォームではなく画面幅
    // (docs/CLAUDE.md)。デスクトップでもウィンドウを狭めれば下置きになる。
    final wide =
        MediaQuery.of(context).size.width >= kOverlayLayerPanelMinWidth;
    final layersOpen = _layersOpen;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        // ⚠ 1 行に固定する。狭幅では「戻る + タイトル + レイヤー + 完了」で
        // AppBar の幅を使い切り、折り返すと固定高の中で overflow する (#1126)。
        title: Text(
          widget.title ?? '文字・スタンプを入れる',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (image != null)
            IconButton(
              key: overlayLayerToggleKey,
              icon: Icon(
                layersOpen ? Icons.layers : Icons.layers_outlined,
                color: Colors.white,
              ),
              tooltip: layersOpen ? 'レイヤー一覧を閉じる' : 'レイヤー一覧',
              onPressed: () => setState(() => _layersOpen = !layersOpen),
            ),
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
          : _buildBody(image, size, wide: wide, layersOpen: layersOpen),
    );
  }

  /// 本文の組み立て (#1126)。
  ///
  /// 広い幅では一覧をキャンバスの**横**に常設し、狭い幅ではキャンバスの**下**へ
  /// 畳んで開閉する。⚠ **どちらも同じ [_buildLayerList] を置くだけ**にしてある。
  /// 狭幅側をモーダルシートにしないのは、削除の取り消し（SnackBar）が
  /// モーダルルートの**下**に出て押せなくなるため。同じ Scaffold の中に置けば
  /// 一覧を開いたまま取り消せる。
  Widget _buildBody(
    Uint8List image,
    Size size, {
    required bool wide,
    required bool layersOpen,
  }) {
    final editor = Column(
      children: [
        Expanded(child: _buildCanvas(image, size)),
        if (!wide && layersOpen)
          SizedBox(
            height: kOverlayLayerListCollapsedHeight,
            child: _buildLayerList(image, size),
          ),
        _buildToolbar(),
      ],
    );
    if (!wide || !layersOpen) return editor;
    return Row(
      children: [
        Expanded(child: editor),
        SizedBox(
          width: kOverlayLayerPanelWidth,
          child: _buildLayerList(image, size),
        ),
      ],
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
          onTap: () => setState(() => _selectedId = null),
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
                    // ⚠ レイヤ一覧のサムネにも同じウィジェットが出る。「プレビューに
                    // 何がどの順で載っているか」を見るときの絞り込み先 (#1126)。
                    key: overlayCanvasKey,
                    children: [
                      Positioned.fill(
                        child: Image.memory(image, fit: BoxFit.fill),
                      ),
                      for (final item in _items)
                        _buildItemWidget(item, dispW, dispH),
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

  Widget _buildItemWidget(_OverlayItem item, double dispW, double dispH) {
    final selected = _selectedId == item.id;
    return Positioned(
      // 並べ替えても同じレイヤの要素を使い回す (#1125)。
      key: ValueKey(item.id),
      left: item.nx * dispW,
      top: item.ny * dispH,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        // ⚠ **回転は GestureDetector の外側に置く。** [Transform] はレイアウト
        // 寸法を変えないので、内側に置くと当たり判定だけ回らない矩形のまま残り、
        // 「枠は傾いているのに掴めるのは元の位置」になる。外側なら
        // `transformHitTests`（既定 true）がポインタを子の座標系へ写す。
        //
        // ドラッグの `details.delta` はグローバル座標由来なので回転の影響を
        // 受けず、下の pan 処理（画面座標で nx / ny を動かす）はそのままでよい。
        child: Transform.rotate(
          angle: item.angle,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _selectedId = item.id),
            onPanUpdate: (details) {
              setState(() {
                item.nx = (item.nx + details.delta.dx / dispW).clamp(0.0, 1.0);
                item.ny = (item.ny + details.delta.dy / dispH).clamp(0.0, 1.0);
                _selectedId = item.id;
              });
            },
            child: _buildItemContent(item, dispW, dispH, selected: selected),
          ),
        ),
      ),
    );
  }

  /// レイヤ 1 枚の見た目。**編集キャンバスとレイヤ一覧のサムネが共有する** (#1126)。
  ///
  /// ⚠ [dispH] を基準高さとして受け取るのが肝。キャンバスなら画像の表示高さ、
  /// サムネなら縮図の高さを渡せば、同じ式のまま縮尺だけ変わる。**サムネ用に
  /// 別の描き方を足さない**——足した瞬間に「一覧で見た向き / 比率」と本番が割れる。
  Widget _buildItemContent(
    _OverlayItem item,
    double dispW,
    double dispH, {
    required bool selected,
    // ⚠ サムネでは切る。40px の縮図に tooltip は邪魔だし、**同じ文言の
    // tooltip が 2 つ出ると `find.byTooltip` が一意に当たらなくなる** (#1126)。
    bool tooltip = true,
  }) {
    return Container(
      // 折り返し幅の上限は**文字レイヤ専用**。書き出し側の
      // `painter.layout(maxWidth: w * kOverlayTextWrapFraction)` と
      // 対になっている（同じ定数を使うのが対であることの担保）。スタンプに
      // 掛けると RawImage が縮んでプレビューだけ小さくなり、書き出し
      // (drawImageRect は制約を受けない) と食い違う。
      constraints: item is _TextOverlayItem
          ? BoxConstraints(maxWidth: dispW * kOverlayTextWrapFraction)
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
        _StickerOverlayItem() => _buildStickerPreview(
          item,
          dispH,
          tooltip: tooltip,
        ),
      },
    );
  }

  Widget _buildStickerPreview(
    _StickerOverlayItem item,
    double dispH, {
    bool tooltip = true,
  }) {
    // 書き出しとまったく同じ式で寸法を出す。ここが割れると WYSIWYG が崩れる。
    final rect = stickerOverlayRect(
      center: Offset.zero,
      sizeFrac: item.sizeFrac,
      aspect: item.aspect,
      referenceHeight: dispH,
    );
    final image = RawImage(
      image: item.image,
      width: rect.width,
      height: rect.height,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.high,
    );
    if (!tooltip) return image;
    return Tooltip(message: ':${item.shortcode}:', child: image);
  }

  /// レイヤ一覧 (#1126)。**最前面が先頭**で、ドラッグで重ね順を変えられる。
  ///
  /// ⚠ **ポインタ 1 本で完結する形にする。**2 本指の回転ジェスチャを採らなかったのと
  /// 同じ理由で（デスクトップ 3 OS に入力手段が無い）、掴み手は
  /// [ReorderableDragStartListener] を明示的に置く。
  Widget _buildLayerList(Uint8List image, Size size) {
    final layers = _layersFrontFirst;
    // ⚠ `Material` で敷く。`Container(color:)` だと `ListTile` の ink が塗れず、
    // 「不透明な ColoredBox の上に ListTile を置くな」と落ちる (#1126)。
    return Material(
      color: const Color(0xFF1A1A1A),
      child: layers.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'テキストやスタンプを追加すると、ここに重ね順が出ます',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
            )
          : ListTileTheme(
              textColor: Colors.white,
              iconColor: Colors.white70,
              selectedColor: Colors.lightBlueAccent,
              selectedTileColor: Colors.white10,
              child: ReorderableListView.builder(
                key: overlayLayerListKey,
                buildDefaultDragHandles: false,
                padding: EdgeInsets.zero,
                itemCount: layers.length,
                onReorderItem: _reorderLayers,
                itemBuilder: (context, index) {
                  final item = layers[index];
                  return ListTile(
                    // 並べ替えても同じレイヤの行を使い回す (#1125)。
                    key: ValueKey(item.id),
                    dense: true,
                    selected: _selectedId == item.id,
                    contentPadding: const EdgeInsets.only(left: 4, right: 4),
                    onTap: () => setState(() => _selectedId = item.id),
                    leading: ReorderableDragStartListener(
                      index: index,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.drag_handle, size: 18),
                          const SizedBox(width: 4),
                          _buildLayerThumb(item, image, size),
                        ],
                      ),
                    ),
                    title: Row(
                      children: [
                        Icon(item.icon, size: 14, color: Colors.white54),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      tooltip: 'このレイヤーを削除',
                      onPressed: () => _deleteLayer(item),
                    ),
                  );
                },
              ),
            ),
    );
  }

  /// レイヤ一覧のサムネ。**画像ごと縮めた縮図**として描く (#1126)。
  ///
  /// 元画像を薄く敷いたうえに当該レイヤだけを載せるので、「どのレイヤが画像の
  /// どこにいるか」が一覧で分かる。⚠ **寸法は [overlayThumbSize] →
  /// [_buildItemContent] と、キャンバス / 書き出しと同じ経路を通す**（3 回目の描画）。
  Widget _buildLayerThumb(_OverlayItem item, Uint8List image, Size size) {
    final thumb = overlayThumbSize(size);
    return SizedBox(
      width: thumb.width,
      height: thumb.height,
      child: ClipRect(
        child: Stack(
          children: [
            Positioned.fill(
              child: Opacity(
                opacity: 0.35,
                child: Image.memory(image, fit: BoxFit.fill),
              ),
            ),
            Positioned(
              left: item.nx * thumb.width,
              top: item.ny * thumb.height,
              child: FractionalTranslation(
                translation: const Offset(-0.5, -0.5),
                child: Transform.rotate(
                  angle: item.angle,
                  child: _buildItemContent(
                    item,
                    thumb.width,
                    thumb.height,
                    selected: false,
                    tooltip: false,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    final item = _selectedItem;
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
              // 回転は文字とスタンプの両方に効く (#946)。片方だけに付けると、
              // 同じキャンバス上の 2 種類のレイヤで操作体系が食い違う。
              _buildAngleRow(item),
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

  /// 回転角の操作行 (#946)。
  ///
  /// **2 本指の回転ジェスチャは採らない。** デスクトップ 3 OS では入力手段が
  /// 無く、「UI の分岐軸はプラットフォームではなく画面幅」(docs/CLAUDE.md) と
  /// 噛み合わない。大きさと同じスライダに揃える。
  ///
  /// ⚠ **リセットボタンは飾りではない。** スライダは連続値なので、一度傾けると
  /// 正確な 0° へ戻すのが難しい。吸着（スナップ）を入れない判断
  /// （[kOverlayMaxAngle] の doc）とセットで要る導線。
  Widget _buildAngleRow(_OverlayItem item) {
    return Row(
      children: [
        const Icon(Icons.rotate_right, color: Colors.white, size: 20),
        Expanded(
          child: Slider(
            key: overlayAngleSliderKey,
            value: item.angle.clamp(kOverlayMinAngle, kOverlayMaxAngle),
            min: kOverlayMinAngle,
            max: kOverlayMaxAngle,
            label: overlayAngleLabel(item.angle),
            onChanged: (v) => setState(() => item.angle = v),
          ),
        ),
        // 現在角度を数値でも出す。スライダの位置だけだと「ほぼ真っ直ぐ」なのか
        // 「少しだけ傾いている」のかが見分けられない。
        SizedBox(
          width: 48,
          child: Text(
            overlayAngleLabel(item.angle),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.restart_alt, color: Colors.white),
          tooltip: '角度をリセット',
          onPressed: item.angle == 0
              ? null
              : () => setState(() => item.angle = 0),
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
            key: overlaySizeSliderKey,
            value: item.sizeFrac,
            // スタンプは絵として見せるので、文字より大きく引き伸ばせる。
            min: kOverlayMinSizeFrac,
            max: isText ? kOverlayMaxTextSizeFrac : kOverlayMaxStickerSizeFrac,
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

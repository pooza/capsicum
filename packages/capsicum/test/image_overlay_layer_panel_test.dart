import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:capsicum/src/ui/screen/image_overlay_screen.dart';
import 'package:capsicum/src/ui/util/image_overlay_geometry.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/image_editor_harness.dart';

/// #1126（#884-B）: レイヤ一覧と重ね順の入れ替え、および削除の取り消し。
///
/// ⚠ **画素の検査は「同じ座標に 2 枚重ねて、出てきた色を見る」**で書く。重ね順は
/// 座標を変えないので、位置や面積では差が出ない。2 枚を**完全に重ねて**おけば、
/// 中心の 1 画素がそのまま「どちらが前面か」の答えになる。
///
/// ⚠⚠ **回転は使わない。**回すとアンチエイリアスが乗り、被覆率がラスタライザで
/// 変わってプラットフォーム間で画素が一致しなくなる（[image_overlay_layer_id_test]
/// の指紋がそれで Linux 限定になっている）。軸に平行なままなら中間色は 0 画素。
void main() {
  const base = Color(0xFF0000FF);
  const green = Color(0xFF00FF00);
  const red = Color(0xFFFF0000);

  final emoji = CustomEmoji(
    shortcode: 'gomechan',
    url: 'https://example.invalid/gomechan.png',
    category: 'ゴメちゃん',
    aliases: const [],
  );

  late Uint8List basePng;
  late ui.Image greenMaster;
  late ui.Image redMaster;

  setUpAll(() async {
    basePng = await solidPng(160, 160, base);
    greenMaster = await solidImage(40, 20, green);
    redMaster = await solidImage(40, 20, red);
  });

  tearDownAll(() {
    greenMaster.dispose();
    redMaster.dispose();
  });

  /// 足した順に緑 → 赤 …… と素材を配る。
  ///
  /// ⚠ **`clone()` を毎回返す。**画面側が `dispose` するので、同じハンドルを配ると
  /// 2 枚目が死んだ画像になる。配ったハンドルは [issued] に控えて、解放されたか
  /// どうか（`debugDisposed`）を後から見る。
  late List<ui.Image> issued;
  FakeStickerSource stickerSource() {
    final masters = [greenMaster, redMaster];
    return FakeStickerSource(
      emoji: emoji,
      imageBuilder: () {
        final image = masters[issued.length % masters.length].clone();
        issued.add(image);
        return image;
      },
    );
  }

  setUp(() => issued = []);

  /// スタンプを 2 枚、同じ位置に重ねた状態まで進める。
  Future<ImageEditorHarness> twoStickers(
    WidgetTester tester, {
    Size surfaceSize = const Size(800, 1000),
  }) async {
    final harness = await ImageEditorHarness.open(
      tester,
      imageData: basePng,
      stickerSource: stickerSource(),
      surfaceSize: surfaceSize,
    );
    await harness.addSticker(); // 緑（背面になる）
    await harness.addSticker(); // 赤（最前面）
    return harness;
  }

  group('重ね順の入れ替え (#1126)', () {
    testWidgets('入れ替える前は、後から足したスタンプが前面', (tester) async {
      final harness = await twoStickers(tester);
      final png = await harness.exportDecoded();
      expect(png.at(80, 80), red, reason: '2 枚目（赤）が上に載っている');
    });

    testWidgets('一覧で入れ替えると、書き出しの前後が入れ替わる', (tester) async {
      final harness = await twoStickers(tester);
      await harness.openLayers();

      // 一覧は**最前面が先頭**。先頭（赤）を 1 つ後ろへ送る。
      expect(harness.layerTiles, findsNWidgets(2));
      await _reorder(tester, 0, 1);

      final png = await harness.exportDecoded();
      expect(png.at(80, 80), green, reason: '入れ替えたので 1 枚目（緑）が上になる');
    });

    testWidgets('入れ替えはプレビューにも同じ順で効く', (tester) async {
      final harness = await twoStickers(tester);
      await harness.openLayers();

      // プレビューは Stack の子の順＝背面から前面。
      expect(harness.canvasStickers(issued), [issued[0], issued[1]]);

      await _reorder(tester, 0, 1);
      expect(harness.canvasStickers(issued), [
        issued[1],
        issued[0],
      ], reason: '書き出しだけでなく編集画面の重なりも入れ替わる');
    });

    testWidgets('入れ替えても選択は同じレイヤについていく (#1125)', (tester) async {
      final harness = await twoStickers(tester); // 2 枚目（赤・一覧の先頭）が選択されている
      await harness.openLayers();
      expect(_selectedTileIndex(harness), 0);

      await _reorder(tester, 0, 1);
      expect(
        _selectedTileIndex(harness),
        1,
        reason: '選択は添字ではなく ID で持っているので、動かした行が選ばれたまま',
      );
    });
  });

  group('削除の取り消し (#1126 / #1131)', () {
    testWidgets('「元に戻す」で、消したレイヤが元の重ね順の位置へ戻る', (tester) async {
      final harness = await twoStickers(tester);
      await harness.openLayers();

      // 一覧の 2 行目＝背面＝1 枚目（緑）を消す。
      await tester.tap(find.byTooltip('このレイヤーを削除').at(1));
      await _snackBarShown(tester);
      expect(harness.canvasStickers(issued), [issued[1]], reason: '緑が消えた');

      await tester.tap(find.text('元に戻す'));
      await tester.pumpAndSettle();

      expect(harness.canvasStickers(issued), [
        issued[0],
        issued[1],
      ], reason: '末尾へ積み直すのではなく、元の位置（背面）へ戻る');
      expect(
        issued[0].debugDisposed,
        isFalse,
        reason: '戻したスタンプの ui.Image が生きていないと描けない',
      );
    });

    testWidgets('取り消さなければ ui.Image は必ず解放される（リークしない）', (tester) async {
      final harness = await twoStickers(tester);
      await harness.openLayers();

      await tester.tap(find.byTooltip('このレイヤーを削除').at(1));
      await _snackBarShown(tester);
      expect(
        issued[0].debugDisposed,
        isFalse,
        reason: '取り消せる間は解放しない（戻しても描けなくなる）',
      );

      await _snackBarExpired(tester);
      expect(
        find.text('元に戻す'),
        findsNothing,
        reason:
            '⚠⚠ SnackBar は放っておいても閉じること。アクション付きの SnackBar は '
            'Flutter の既定 (persist = action != null) では時間で閉じず、'
            '`persist: false` を明示しないと解放の上限が消える',
      );
      expect(issued[0].debugDisposed, isTrue, reason: '期限が切れたら解放する');
    });

    testWidgets('取り消す前に画面を閉じても解放される', (tester) async {
      final harness = await twoStickers(tester);
      await harness.openLayers();

      await tester.tap(find.byTooltip('このレイヤーを削除').at(1));
      await tester.pump();

      // ⚠ SnackBar が閉じる前に離脱する。`closed` は ScaffoldMessenger ごと
      // 外れると解決するとは限らないので、State の dispose でも畳む必要がある。
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(issued[0].debugDisposed, isTrue, reason: '取り消し待ちも dispose で畳む');
      expect(issued[1].debugDisposed, isTrue, reason: '一覧に残っていたぶんも解放される');
    });

    testWidgets('連続して消すと、取り消し先は直前の 1 枚に絞られる', (tester) async {
      final harness = await twoStickers(tester);
      await harness.openLayers();

      await tester.tap(find.byTooltip('このレイヤーを削除').at(1)); // 緑
      await tester.pump();
      await tester.tap(find.byTooltip('このレイヤーを削除').first); // 赤
      await tester.pumpAndSettle();

      expect(find.text('元に戻す'), findsOneWidget, reason: 'SnackBar は 1 本に畳まれる');
      expect(
        issued[0].debugDisposed,
        isTrue,
        reason: '前の SnackBar を閉じた時点で、そちらは取り消し不能が確定する',
      );

      await tester.tap(find.text('元に戻す'));
      await tester.pumpAndSettle();
      expect(harness.canvasStickers(issued), [
        issued[1],
      ], reason: '戻るのは直前の 1 枚だけ');
    });
  });

  group('置き場所は画面幅で決める (#1126)', () {
    testWidgets('320px 幅で一覧を開いても overflow しない', (tester) async {
      final harness = await twoStickers(
        tester,
        surfaceSize: const Size(320, 800),
      );
      await harness.openLayers();
      expect(harness.layerTiles, findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('320px 幅 + テキストスケール 1.3 でも overflow しない', (tester) async {
      await _pumpScaled(tester, basePng, width: 320, textScale: 1.3);
      await tester.tap(find.byKey(overlayLayerToggleKey));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('既定は閉じた状態（開いていないのに編集面を削らない）', (tester) async {
      await twoStickers(tester);
      expect(find.byKey(overlayLayerListKey), findsNothing);
      expect(find.byKey(overlayLayerToggleKey), findsOneWidget);
    });

    testWidgets('広い幅ではキャンバスの横、狭い幅では下に出る', (tester) async {
      final wide = await twoStickers(
        tester,
        surfaceSize: const Size(900, 1000),
      );
      await wide.openLayers();
      final wideList = tester.getRect(find.byKey(overlayLayerListKey));
      final wideCanvas = tester.getRect(find.byKey(overlayCanvasKey));
      expect(
        wideList.left,
        greaterThanOrEqualTo(wideCanvas.right),
        reason: '横に並ぶ',
      );
      expect(wideList.width, kOverlayLayerPanelWidth);

      final narrow = await twoStickers(
        tester,
        surfaceSize: const Size(400, 1000),
      );
      await narrow.openLayers();
      final narrowList = tester.getRect(find.byKey(overlayLayerListKey));
      final narrowCanvas = tester.getRect(find.byKey(overlayCanvasKey));
      expect(
        narrowList.top,
        greaterThanOrEqualTo(narrowCanvas.bottom),
        reason: '下に積む',
      );
      expect(narrowList.height, kOverlayLayerListCollapsedHeight);
    });
  });

  group('overlayThumbSize', () {
    test('正方形の画像は箱いっぱい', () {
      expect(
        overlayThumbSize(const Size(160, 160), extent: 40),
        const Size(40, 40),
      );
    });

    test('横長は高さが縮み、縦長は幅が縮む（縦横比を保つ）', () {
      expect(
        overlayThumbSize(const Size(160, 80), extent: 40),
        const Size(40, 20),
      );
      expect(
        overlayThumbSize(const Size(80, 160), extent: 40),
        const Size(20, 40),
      );
    });
  });
}

/// 取り消しの SnackBar が完全に出るまで進める。
///
/// ⚠ **登場アニメーションを終わらせるまで押せない。**`pump()` 1 回では画面外から
/// 滑り込む途中で、「元に戻す」を叩いても当たらない。
Future<void> _snackBarShown(WidgetTester tester) async {
  await tester.pump();
  await tester.pumpAndSettle();
}

/// 取り消しの期限（[kOverlayUndoWindow]）が切れて SnackBar が閉じるまで進める。
///
/// ⚠⚠ **1 回の大きな `pump` では閉じない。**表示時間のタイマーは**登場アニメーションが
/// 終わってから**仕掛けられるので、登場ぶんと表示ぶんは別々に進める必要がある。
/// また、タイマーが走っている間はフレームが積まれないので `pumpAndSettle` は
/// 即座に戻ってしまう（＝「待ったつもり」で待てていない）。
Future<void> _snackBarExpired(WidgetTester tester) async {
  await _snackBarShown(tester);
  await tester.pump(kOverlayUndoWindow + const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

/// ドラッグの代わりに `onReorderItem` を直接呼ぶ。
///
/// ⚠ **添字の流儀ごと検査したいのでこの形にする。**`tester.drag` で動かすと
/// Flutter 側の補正を通った後の値しか見られず、こちらの読み替え（一覧は最前面が
/// 先頭・`_items` は末尾が最前面）が合っているかを確かめられない。
Future<void> _reorder(WidgetTester tester, int oldIndex, int newIndex) async {
  final list = tester.widget<ReorderableListView>(
    find.byKey(overlayLayerListKey),
  );
  list.onReorderItem!(oldIndex, newIndex);
  await tester.pumpAndSettle();
}

/// 一覧の中で選択されている行の位置。
int _selectedTileIndex(ImageEditorHarness harness) => harness.tester
    .widgetList<ListTile>(harness.layerTiles)
    .toList()
    .indexWhere((t) => t.selected);

/// テキストスケールを変えて画面を立ち上げる（[ImageEditorHarness] は等倍専用）。
Future<void> _pumpScaled(
  WidgetTester tester,
  Uint8List png, {
  required double width,
  required double textScale,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: ImageOverlayScreen(imageData: png),
      ),
    ),
  );
  // `_decode()` は本物のコーデックを回すので、擬似非同期のままでは完了しない。
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  await tester.pump();
}

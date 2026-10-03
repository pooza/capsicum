import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:capsicum/src/model/image_overlay_layer.dart';
import 'package:capsicum/src/service/sticker_source.dart';
import 'package:capsicum/src/ui/util/image_overlay_geometry.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/image_editor_harness.dart';

/// #1129（#884-E）: 焼き込みでレイヤが消えるのをやめ、再編集できるようにする。
///
/// ⚠⚠ **「レイヤ管理」を名乗る以上ここが本丸。**A〜D を全部入れても、閉じた瞬間に
/// 消えるなら管理にならない。編集画面は**焼き込み済みの PNG とレイヤ列の両方**を
/// 返し、次に開くときは**焼き込み前の画像 + そのレイヤ列**で開く。
///
/// ⚠ **スタンプは `ui.Image` を持ち出さない。**ショートコードと URL で覚え、
/// 再入時に取り直す。添付ごとに原寸画像を抱えるとネイティブ側のメモリが積む。
void main() {
  const base = Color(0xFF0000FF);
  const green = Color(0xFF00FF00);

  final emoji = CustomEmoji(
    shortcode: 'gomechan',
    url: 'https://example.invalid/gomechan.png',
    category: 'ゴメちゃん',
    aliases: const [],
  );

  late Uint8List basePng;
  late ui.Image greenMaster;

  setUpAll(() async {
    basePng = await solidPng(160, 160, base);
    greenMaster = await solidImage(40, 20, green);
  });

  tearDownAll(() => greenMaster.dispose());

  late List<ui.Image> issued;
  setUp(() => issued = []);

  FakeStickerSource source() => FakeStickerSource(
    emoji: emoji,
    imageBuilder: () {
      final image = greenMaster.clone();
      issued.add(image);
      return image;
    },
  );

  group('レイヤ列が編集画面の外へ出る (#1129)', () {
    testWidgets('完了すると、焼き込み済みの画像とレイヤ列の両方が返る', (tester) async {
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        stickerSource: source(),
      );
      await harness.addText('おはよう');
      await harness.addSticker();
      await harness.setOpacity(0.6);

      final png = await harness.exportDecoded();
      expect(png.width, 160, reason: '焼き込み済みの画像は従来どおり返る');

      final layers = harness.exportedLayers;
      expect(layers, hasLength(2));
      expect(layers![0], isA<TextOverlayLayerSpec>());
      expect((layers[0] as TextOverlayLayerSpec).text, 'おはよう');
      final sticker = layers[1] as StickerOverlayLayerSpec;
      expect(sticker.shortcode, 'gomechan');
      expect(
        sticker.url,
        emoji.url,
        reason: '⚠ 再入時はここから取り直すので、URL を覚えていないと復元できない',
      );
      expect(sticker.opacity, closeTo(0.6, 0.01), reason: '#1128 の値も持ち出す');
    });

    testWidgets('キャンセルするとレイヤ列も返らない', (tester) async {
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        stickerSource: source(),
      );
      await harness.addText('捨てる');
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(harness.closed, isTrue);
      expect(harness.exported, isNull);
      expect(harness.exportedLayers, isNull);
    });

    testWidgets('レイヤの状態が 1 つ残らず持ち出される', (tester) async {
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        stickerSource: source(),
      );
      await harness.addSticker();
      await harness.setSize(0.4);
      await harness.setAngleDegrees(25);
      await harness.setOpacity(0.4);
      await tester.drag(harness.canvasSticker(issued[0]), const Offset(30, 20));
      await harness.settle();
      await harness.openLayers();
      await tester.tap(find.byTooltip('このレイヤーを隠す'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('このレイヤーをロックする'));
      await tester.pumpAndSettle();

      await harness.export();
      final spec = harness.exportedLayers!.single;
      // ⚠ スライダの値は `min + (max - min) * 割合`。下限を忘れると 0.018 ずれる。
      expect(
        spec.sizeFrac,
        closeTo(
          kOverlayMinSizeFrac +
              (kOverlayMaxStickerSizeFrac - kOverlayMinSizeFrac) * 0.4,
          0.01,
        ),
      );
      expect(spec.angle, closeTo(25 * math.pi / 180, 0.01));
      expect(spec.opacity, closeTo(0.4, 0.01));
      expect(spec.visible, isFalse, reason: '非表示 (#1127) も控える');
      expect(spec.locked, isTrue, reason: 'ロック (#1127) も控える');
      expect(spec.nx, greaterThan(0.5), reason: '動かした位置が残る');
      expect(spec.ny, greaterThan(0.5));
    });
  });

  group('再入すると前回のレイヤが編集できる (#1129)', () {
    testWidgets('⚠⚠ 開き直したときに、前回のレイヤが一覧にいる', (tester) async {
      final first = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        stickerSource: source(),
      );
      await first.addText('また会おう');
      await first.addSticker();
      await first.export();

      final again = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        stickerSource: source(),
        initialLayers: first.exportedLayers!,
      );
      await again.openLayers();
      expect(again.layerTiles, findsNWidgets(2));
      expect(find.text('また会おう'), findsWidgets, reason: '文字レイヤが戻っている');
      expect(
        again.canvasStickers(issued),
        hasLength(1),
        reason: 'スタンプは URL から取り直して載る',
      );
    });

    testWidgets('⚠⚠ 開き直してそのまま完了すると、焼き込み結果が 1 回目と同じ', (tester) async {
      final first = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        stickerSource: source(),
      );
      await first.addText('同じ画');
      await first.addSticker();
      await first.setOpacity(0.5);
      await first.setAngleDegrees(15);
      final before = await first.exportDecoded();

      final again = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        stickerSource: source(),
        initialLayers: first.exportedLayers!,
      );
      final after = await again.exportDecoded();

      expect(
        after.fingerprint,
        before.fingerprint,
        reason: '⚠ 復元が 1 項目でも欠けると、ここが真っ先に割れる',
      );
    });

    // ⚠⚠ **可視とロックを戻し忘れると、ここだけが落ちる。**上の「焼き込み結果が
    // 同じ」は全部見えているレイヤで撮っているので、非表示が戻らなくても通る。
    // 戻らないと、**開いて完了しただけで隠したレイヤが画に出てくる。**
    testWidgets('⚠⚠ 非表示とロックも復元される', (tester) async {
      final first = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        stickerSource: source(),
      );
      await first.addSticker();
      await first.addSticker();
      await first.openLayers();
      // 一覧は最前面が先頭。先頭（2 枚目）を隠し、2 行目をロックする。
      await tester.tap(find.byTooltip('このレイヤーを隠す').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('このレイヤーをロックする').last);
      await tester.pumpAndSettle();
      final before = await first.exportDecoded();

      final again = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        stickerSource: source(),
        initialLayers: first.exportedLayers!,
      );
      await again.openLayers();
      expect(
        find.byTooltip('このレイヤーを表示する'),
        findsOneWidget,
        reason: '隠したままの行が 1 つある（戻っていれば「隠す」に変わっている）',
      );
      expect(
        find.byTooltip('ロックを解除する'),
        findsOneWidget,
        reason: 'ロックしたままの行が 1 つある',
      );
      expect(
        again.canvasStickers(issued),
        hasLength(1),
        reason: '隠したレイヤはプレビューにも出ない',
      );

      final after = await again.exportDecoded();
      expect(
        after.fingerprint,
        before.fingerprint,
        reason: '⚠⚠ 可視が戻らないと、開いて完了しただけで隠したレイヤが画に出る',
      );
    });

    testWidgets('復元したレイヤをそのまま編集できる（読み込み専用にならない）', (tester) async {
      final first = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        stickerSource: source(),
      );
      await first.addSticker();
      await first.export();

      final again = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        stickerSource: source(),
        initialLayers: first.exportedLayers!,
      );
      await tester.tap(again.canvasSticker(issued[1]));
      await again.settle();
      await again.setOpacity(0.25);

      await again.export();
      expect(again.exportedLayers!.single.opacity, closeTo(0.25, 0.01));
    });

    testWidgets('⚠ 素材を取り直せなかったレイヤは落として、黙らない', (tester) async {
      const spec = StickerOverlayLayerSpec(
        shortcode: 'gone',
        url: 'https://example.invalid/gone.png',
        nx: 0.5,
        ny: 0.5,
        sizeFrac: 0.2,
        angle: 0,
        opacity: 1,
        visible: true,
        locked: false,
      );
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        stickerSource: _FailingStickerSource(),
        initialLayers: const [spec],
      );

      // ⚠ **件数は数えない。**復元は画面が出てくる途中（遷移アニメーション中）に
      // 終わるので、`ScaffoldMessenger` が下の画面の Scaffold にも同じ SnackBar を
      // 組み立てる。出ていること自体が検査の目的。
      expect(
        find.textContaining('復元できませんでした'),
        findsWidgets,
        reason: '⚠ 黙って落とすと、開いて完了しただけでスタンプが消えた画像になる',
      );
      expect(find.textContaining('1 個'), findsWidgets, reason: '何枚落ちたかを言う');
      await harness.openLayers();
      expect(harness.layerTiles, findsNothing);

      // 落ちたぶんを除いた状態で、書き出しは通る（画面が壊れない）。
      final png = await harness.exportDecoded();
      expect(png.at(80, 80), base);
    });

    testWidgets('⚠ 取り直した ui.Image も、画面を閉じるときに解放される', (tester) async {
      final first = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        stickerSource: source(),
      );
      await first.addSticker();
      await first.export();
      expect(issued, hasLength(1));

      final again = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        stickerSource: source(),
        initialLayers: first.exportedLayers!,
      );
      expect(issued, hasLength(2), reason: '再入で取り直している');
      expect(issued[1].debugDisposed, isFalse);

      await again.export();
      // ⚠ route が実際に外れるまで State の dispose は走らない。
      await tester.pumpAndSettle();
      expect(
        issued[1].debugDisposed,
        isTrue,
        reason: '⚠ 添付ごとに原寸画像を抱えないための前提（画面が出るときに解放する）',
      );
    });
  });
}

/// 素材の取得が必ず失敗する [StickerSource]（絵文字がサーバーから消えた場合）。
class _FailingStickerSource implements StickerSource {
  @override
  Future<CustomEmoji?> pick({
    required BuildContext context,
    required WidgetRef ref,
  }) async => null;

  @override
  Future<ui.Image> load(String url) async =>
      throw StateError('sticker is gone');
}

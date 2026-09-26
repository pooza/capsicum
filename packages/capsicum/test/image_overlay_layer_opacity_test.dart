import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:capsicum/src/ui/screen/image_overlay_screen.dart';
import 'package:capsicum/src/ui/util/image_overlay_geometry.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/image_editor_harness.dart';

/// #1128（#884-D）: レイヤごとの不透明度。
///
/// ⚠⚠ **色の alpha ではなく「グループ不透明度」で掛ける。**文字レイヤは本体と
/// 4 方向の擬似アウトラインが重なっているので、色ごとに alpha を掛けると
/// **重なった部分だけ二重に合成されて濃く出る**。プレビューの `Opacity` は
/// 1 枚に描いてから alpha を掛けるので、書き出しも `saveLayer` で同じ意味に
/// しないと WYSIWYG が割れる。その差は「文字レイヤは二重に合成しない」の
/// グループが数値で押さえている。
///
/// ⚠⚠ **`saveLayer` に bounds を渡さないこと**も、そこの全画素検査が歯になっている
/// （渡すとアウトラインの外周 1 列 / 1 行が落ちる。2026-09-23 実測）。
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

  Future<ImageEditorHarness> withSticker(WidgetTester tester) async {
    final harness = await ImageEditorHarness.open(
      tester,
      imageData: basePng,
      stickerSource: FakeStickerSource(
        emoji: emoji,
        imageBuilder: greenMaster.clone,
      ),
    );
    await harness.addSticker();
    return harness;
  }

  group('不透明度 (#1128)', () {
    testWidgets('既定は 100%（何もしなければ従来どおり不透明）', (tester) async {
      final harness = await withSticker(tester);
      expect(_previewOpacity(tester), kOverlayDefaultOpacity);

      final png = await harness.exportDecoded();
      expect(png.at(80, 80), green, reason: '既定では合成が挟まらない');
    });

    testWidgets('下げるとプレビューに通る', (tester) async {
      final harness = await withSticker(tester);
      await harness.setOpacity(0.5);
      expect(_previewOpacity(tester), closeTo(0.5, 0.001));
    });

    testWidgets('⚠ 下げると書き出しにも通る（プレビューだけ薄くならない）', (tester) async {
      final harness = await withSticker(tester);
      await harness.setOpacity(0.5);

      final png = await harness.exportDecoded();
      final p = png.at(80, 80);
      expect(p, isNot(green), reason: 'そのままの緑ではない');
      expect(p, isNot(base), reason: '消えてもいない');
      // 緑 (0,255,0) を 50% で青 (0,0,255) に載せた結果。
      expect((p.g * 255).round(), closeTo(128, 3));
      expect((p.b * 255).round(), closeTo(127, 3));
    });

    testWidgets('⚠ 不透明度 0 のレイヤは書き出しに出ない', (tester) async {
      final harness = await withSticker(tester);
      await harness.setOpacity(0);

      final png = await harness.exportDecoded();
      expect(png.at(80, 80), base);
      expect(png.countNear(green), 0, reason: '1 画素も残らない');
    });

    testWidgets('⚠ 不透明度 0 の書き出しは、#1127 の非表示とまったく同じ画', (tester) async {
      final transparent = await withSticker(tester);
      await transparent.setOpacity(0);
      final byOpacity = await transparent.exportDecoded();

      final hidden = await withSticker(tester);
      await hidden.openLayers();
      await tester.tap(find.byTooltip('このレイヤーを隠す'));
      await tester.pumpAndSettle();
      final byVisibility = await hidden.exportDecoded();

      expect(
        byOpacity.fingerprint,
        byVisibility.fingerprint,
        reason: '不透明度 0 と非表示は結果が一致する（別の概念だが画は同じ）',
      );
    });

    testWidgets('リセットで 100% に戻る（スライダだけだと戻しにくい）', (tester) async {
      final harness = await withSticker(tester);
      await harness.setOpacity(0.3);
      expect(find.text('30%'), findsOneWidget, reason: '現在値が数値でも出る');

      await tester.tap(find.byTooltip('不透明度をリセット'));
      await tester.pump();
      expect(_previewOpacity(tester), kOverlayDefaultOpacity);
      expect(find.text('100%'), findsOneWidget);
    });

    testWidgets('ロック中は動かせない (#1127)', (tester) async {
      final harness = await withSticker(tester);
      await harness.openLayers();
      await tester.tap(find.byTooltip('このレイヤーをロックする'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Slider>(find.byKey(overlayOpacitySliderKey)).onChanged,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find
                  .ancestor(
                    of: find.byTooltip('不透明度をリセット'),
                    matching: find.byType(IconButton),
                  )
                  .first,
            )
            .onPressed,
        isNull,
      );
    });
  });

  group('⚠⚠ 文字レイヤは二重に合成しない (#1128)', () {
    // 文字は「白い本体 + 黒い擬似アウトライン（4 方向の shadow）」が重なっている。
    //
    // - **グループ不透明度**（正しい）: 1 枚に描いてから 50% を掛けるので、
    //   グリフの内側は「白を 50% で青に載せた色」＝ 青チャンネルは 255 のまま。
    // - **色ごとの alpha**（誤り）: 黒いアウトラインを 50% で青に載せた上に、
    //   さらに白を 50% で載せることになり、**青チャンネルが 191 付近まで落ちる**。
    //
    // ⚠ 赤チャンネルはどちらも 128 付近で差が出ない。**見分けが付くのは青だけ。**
    testWidgets('グリフの内側で、下地の青が食われない', (tester) async {
      final harness = await ImageEditorHarness.open(tester, imageData: basePng);
      await harness.addText('A');
      await harness.setOpacity(0.5);

      final png = await harness.exportDecoded();
      final p = png.at(80, 80);
      expect(
        (p.r * 255).round(),
        closeTo(128, 3),
        reason: '白い文字が 50% で載っている（0 なら文字がそもそも出ていない）',
      );
      expect((p.b * 255).round(), 255, reason: '⚠⚠ 二重合成なら 191 付近まで落ちる');
    });

    // ⚠⚠ **1 画素の検査では「たまたまそこだけ合っている」を排除できない。**
    // グループ不透明度なら、**どの画素でも**
    // `50% の書き出し = 0.5 × 不透明の書き出し + 0.5 × 元画像`
    // が成り立つ。合成を掛ける場所を間違えると、重なっている画素だけこの式から
    // 外れる。回転を使っていないので中間色は glyph の縁だけで、丸め誤差も小さい。
    testWidgets('全画素で「不透明な書き出しと元画像の中間」になっている', (tester) async {
      final opaqueRun = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
      );
      await opaqueRun.addText('A');
      final opaque = await opaqueRun.exportDecoded();

      final halfRun = await ImageEditorHarness.open(tester, imageData: basePng);
      await halfRun.addText('A');
      await halfRun.setOpacity(0.5);
      final half = await halfRun.exportDecoded();

      var worst = 0;
      var worstAt = '';
      var compared = 0;
      for (var y = 0; y < half.height; y++) {
        for (var x = 0; x < half.width; x++) {
          final got = half.at(x, y);
          final src = opaque.at(x, y);
          compared++;
          for (final (name, g, s, b) in [
            ('r', got.r, src.r, base.r),
            ('g', got.g, src.g, base.g),
            ('b', got.b, src.b, base.b),
          ]) {
            final expected = (s * 255 + b * 255) / 2;
            final diff = ((g * 255) - expected).abs().round();
            if (diff > worst) {
              worst = diff;
              worstAt =
                  '($x,$y).$name 期待 ${expected.round()} / 実際 ${(g * 255).round()}';
            }
          }
        }
      }
      // ⚠ **走査が空振りしていないことを固定する。**全画素を回しているつもりでも、
      // 数え間違いで 0 件なら黙って緑になる。
      expect(compared, 160 * 160, reason: '全画素を比べている');
      expect(
        worst,
        lessThanOrEqualTo(2),
        reason: '⚠⚠ 合成を掛ける場所が違うと、重なっている画素だけ式から外れる: $worstAt',
      );
    });

    // 文字は縁にアンチエイリアスとぼかしが乗る。**スタンプは軸に平行で中間色が
    // 0 画素**なので、素材の性質を変えても関係式が崩れないことを別に押さえる。
    testWidgets('スタンプでも全画素が中間になる', (tester) async {
      final opaqueRun = await withSticker(tester);
      final opaque = await opaqueRun.exportDecoded();

      final halfRun = await withSticker(tester);
      await halfRun.setOpacity(0.5);
      final half = await halfRun.exportDecoded();

      var worst = 0;
      for (var y = 0; y < half.height; y++) {
        for (var x = 0; x < half.width; x++) {
          final got = half.at(x, y);
          final src = opaque.at(x, y);
          for (final (g, s, b) in [
            (got.r, src.r, base.r),
            (got.g, src.g, base.g),
            (got.b, src.b, base.b),
          ]) {
            final diff = ((g * 255) - (s * 255 + b * 255) / 2).abs().round();
            if (diff > worst) worst = diff;
          }
        }
      }
      expect(worst, lessThanOrEqualTo(2));
    });
  });

  group('狭幅 (#1128 は行を 1 本足す)', () {
    testWidgets('320px 幅で overflow しない', (tester) async {
      await _pumpAt(tester, basePng, width: 320, height: 800, textScale: 1);
      await _selectFirstLayer(tester);
      expect(find.byKey(overlayOpacitySliderKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('320px 幅 + テキストスケール 1.3 でも overflow しない', (tester) async {
      await _pumpAt(tester, basePng, width: 320, height: 800, textScale: 1.3);
      await _selectFirstLayer(tester);
      expect(tester.takeException(), isNull);
    });

    // ⚠ 行が 1 本増えたぶん、**縦にも余裕が無くなる**。横向きの端末を想定した
    // 低い画面で、ツールバーが画面を割らないことを見る。
    testWidgets('画面が低くても overflow しない（横向き相当）', (tester) async {
      await _pumpAt(tester, basePng, width: 640, height: 360, textScale: 1);
      await _selectFirstLayer(tester);
      expect(tester.takeException(), isNull);
    });
  });
}

/// 編集キャンバスに載っているレイヤの不透明度。
///
/// ⚠ **キャンバス配下に絞る。**一覧のサムネにも同じ [Opacity] が出る。
double _previewOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find
          .descendant(
            of: find.byKey(overlayCanvasKey),
            matching: find.byType(Opacity),
          )
          .first,
    )
    .opacity;

/// テキストを 1 枚足して選択済みにする（操作行を出すため）。
Future<void> _selectFirstLayer(WidgetTester tester) async {
  await tester.tap(find.text('テキストを追加'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'あ');
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

/// 画面サイズとテキストスケールを指定して立ち上げる（[ImageEditorHarness] は
/// 等倍・固定サイズ専用）。
Future<void> _pumpAt(
  WidgetTester tester,
  Uint8List png, {
  required double width,
  required double height,
  required double textScale,
}) async {
  tester.view.physicalSize = Size(width, height);
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
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  await tester.pump();
}

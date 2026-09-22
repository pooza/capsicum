import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:capsicum/src/ui/util/image_overlay_geometry.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/image_editor_harness.dart';

/// #1125: レイヤの同一性を安定 ID にする（#884 の前提工事）。
///
/// ⚠ **書き出し結果を 1px も変えない**ことが完了条件。選択の持ち方を添字から
/// ID へ変えるだけのリファクタなので、画に出るものは何も変わってはいけない。
/// 指紋は**変更前のコードで書き出して取った値**を固定してある。
void main() {
  const base = Color(0xFF0000FF);
  const sticker = Color(0xFF00FF00);

  final emoji = CustomEmoji(
    shortcode: 'gomechan',
    url: 'https://example.invalid/gomechan.png',
    category: 'ゴメちゃん',
    aliases: const [],
  );

  late Uint8List basePng;
  late ui.Image stickerMaster;

  setUpAll(() async {
    basePng = await solidPng(160, 160, base);
    stickerMaster = await solidImage(40, 20, sticker);
  });

  tearDownAll(() => stickerMaster.dispose());

  testWidgets('文字とスタンプを重ね、選び直して回した書き出しが変更前と同じ画素', (tester) async {
    final harness = await ImageEditorHarness.open(
      tester,
      imageData: basePng,
      stickerSource: FakeStickerSource(
        emoji: emoji,
        imageBuilder: stickerMaster.clone,
      ),
    );

    // 文字 → スタンプの順に足す（最後に足したスタンプが選択される）。
    await harness.addText('A');
    await harness.addSticker();
    await harness.setAngleDegrees(30);
    await harness.setSize(0.1);

    // ⚠⚠ **スタンプを脇へずらしてから文字を選ぶ。**どちらも画像の中央に置かれる
    // ので、そのまま `A` をタップすると上に重なったスタンプに当たり、正しい
    // 実装でもスタンプが選ばれる（初版はこれで、選択を壊しても緑だった）。
    // ⚠ スタンプは表示上かなり大きいので、少しずらすだけでは重なったまま。
    // 左上の隅（座標は 0..1 に丸まる）まで寄せる。
    await tester.drag(find.byTooltip(':gomechan:'), const Offset(-600, -600));
    await harness.settle();

    // 先に足した文字を選び直して回す。ここで選ばれるのは「文字」でなければ
    // ならない。
    await tester.tap(find.text('A'));
    await harness.settle();
    // 色の行は文字レイヤを選んでいるときだけ出る（スタンプには色が無い）。
    expect(_colorSwatches, findsNWidgets(6), reason: '文字が選ばれている');
    await harness.setAngleDegrees(-20);

    final png = await harness.exportDecoded();
    expect(png.width, 160);
    expect(png.countNear(sticker), greaterThan(0), reason: 'スタンプが載っている');
    expect(png.fingerprint, _expectedFingerprint);
  });

  group('reorderOverlayLayers（#884-B で使う）', () {
    test('ReorderableListView の newIndex（取り除く前の位置）で並べ替える', () {
      expect(reorderOverlayLayers(['a', 'b', 'c'], 0, 3), ['b', 'c', 'a']);
      expect(reorderOverlayLayers(['a', 'b', 'c'], 2, 0), ['c', 'a', 'b']);
      expect(reorderOverlayLayers(['a', 'b', 'c'], 1, 1), ['a', 'b', 'c']);
      expect(reorderOverlayLayers(['a', 'b', 'c'], 1, 2), ['a', 'b', 'c']);
    });

    test('元の一覧は書き換えない', () {
      final original = ['a', 'b', 'c'];
      reorderOverlayLayers(original, 0, 3);
      expect(original, ['a', 'b', 'c']);
    });
  });
}

/// 変更前（`bb16dde7` 時点の `image_overlay_screen.dart`）で書き出した指紋。
const _expectedFingerprint = 2223183324;

/// 文字レイヤの色の丸（`_buildColorRow`）。
final _colorSwatches = find.byWidgetPredicate(
  (w) =>
      w is Container &&
      w.decoration is BoxDecoration &&
      (w.decoration! as BoxDecoration).shape == BoxShape.circle,
);

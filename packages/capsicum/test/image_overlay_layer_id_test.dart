import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:capsicum/src/ui/util/image_overlay_geometry.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/image_editor_harness.dart';

/// #1125: レイヤの同一性を安定 ID にする（#884 の前提工事）。
///
/// ⚠ **書き出し結果を 1px も変えない**ことが完了条件だった。選択の持ち方を添字から
/// ID へ変えるだけのリファクタなので、画に出るものは何も変わってはいけない。
///
/// ⚠⚠ **ここで見るのは「どのレイヤに操作が当たったか」だけ。**画素で確かめたく
/// なるが、このシナリオは**ドラッグで端まで寄せる**手順を含むので、編集画面の
/// レイアウト（ツールバーの行数）が変わるとキャンバスの大きさが変わり、**着地
/// 位置ごと変わる**。実際 #1128 で不透明度の行を 1 本足したときに、描画は何も
/// 変えていないのに全画素ハッシュが動いて CI が落ちた。
///
/// **画素の固定は [image_overlay_export_golden_test] が受け持つ** —— あちらは
/// `initialLayers` で座標を直接与えるので、レイアウトにも入力手順にも依存しない。
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

  /// 文字とスタンプを重ね、**後から先に足した文字を選び直して回す**まで進める。
  ///
  /// 選択を添字で持っていると、ここで回るのは文字ではなくスタンプになる。
  Future<DecodedPng> runScenario(WidgetTester tester) async {
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
    // ⚠ **キャンバス配下に絞る。**#1126 でレイヤ一覧が付き、一覧を開くと同じ
    // `A` が見出しとサムネにも出る。型や文言だけで拾うと一意に当たらない。
    await tester.tap(_inCanvas(find.text('A')));
    await harness.settle();
    // 色の行は文字レイヤを選んでいるときだけ出る（スタンプには色が無い）。
    expect(_colorSwatches, findsNWidgets(6), reason: '文字が選ばれている');
    await harness.setAngleDegrees(-20);

    // ⚠⚠ **ここが移植可能な歯。**「どのレイヤに角度が当たったか」をウィジェット
    // ツリーで直接見る。画素ハッシュと違ってラスタライザに依存しないので、
    // macOS / Windows でもこの検査だけは必ず走る。選択が添字のままだと、
    // 2 回目の角度がスタンプ側に乗って 2 つとも -20° になる。
    expect(
      _angleDegreesOf(tester, find.text('A')),
      closeTo(-20, 0.5),
      reason: '2 回目の回転は選び直した文字に当たる',
    );
    expect(
      _angleDegreesOf(tester, find.byType(RawImage)),
      closeTo(30, 0.5),
      reason: 'スタンプの角度は 1 回目のまま残る',
    );

    return harness.exportDecoded();
  }

  testWidgets('選び直した回転が、添字ではなくそのレイヤに当たる', (tester) async {
    final png = await runScenario(tester);
    expect(png.width, 160);
    expect(png.countNear(sticker), greaterThan(0), reason: 'スタンプが載っている');
  });

  group('reorderOverlayLayers（#884-B で使う）', () {
    test('onReorderItem の newIndex（取り除いた後の挿入位置）で並べ替える', () {
      expect(reorderOverlayLayers(['a', 'b', 'c'], 0, 2), ['b', 'c', 'a']);
      expect(reorderOverlayLayers(['a', 'b', 'c'], 2, 0), ['c', 'a', 'b']);
      expect(reorderOverlayLayers(['a', 'b', 'c'], 1, 1), ['a', 'b', 'c']);
    });

    // ⚠⚠ **旧 `onReorder` との違いはここに出る。**旧流儀（取り除く**前**の位置）
    // なら `1 → 2` は「b を b 自身の位置へ」＝無変化だが、`onReorderItem` は
    // Flutter 側が `newIndex -= 1` を済ませてから呼ぶので、**1 つ後ろへ動く**のが
    // 正しい。#1125 の初版は旧流儀の補正を持っており、そのまま配線していたら
    // 「後ろへドラッグしても動かない / 1 つ手前に落ちる」になっていた (#1126)。
    test('後ろへ動かすとき二重に補正しない', () {
      expect(reorderOverlayLayers(['a', 'b', 'c'], 1, 2), ['a', 'c', 'b']);
      expect(reorderOverlayLayers(['a', 'b', 'c', 'd'], 0, 1), [
        'b',
        'a',
        'c',
        'd',
      ]);
    });

    test('元の一覧は書き換えない', () {
      final original = ['a', 'b', 'c'];
      reorderOverlayLayers(original, 0, 2);
      expect(original, ['a', 'b', 'c']);
    });
  });
}

/// キャンバス（画像と同じ矩形）配下に絞り込む (#1126)。
Finder _inCanvas(Finder matching) =>
    find.descendant(of: find.byKey(overlayCanvasKey), matching: matching);

/// [leaf] を包む最も近い [Transform] の回転角（度）。
///
/// プレビューの回転は `Transform.rotate`（＝ Z 軸まわりの回転行列）なので、
/// 行列の先頭 2 要素が `cos` / `sin` に入る。
double _angleDegreesOf(WidgetTester tester, Finder leaf) {
  final transform = find
      .ancestor(of: _inCanvas(leaf), matching: find.byType(Transform))
      .first;
  final m = tester.widget<Transform>(transform).transform.storage;
  return math.atan2(m[1], m[0]) * 180 / math.pi;
}

/// 文字レイヤの色の丸（`_buildColorRow`）。
final _colorSwatches = find.byWidgetPredicate(
  (w) =>
      w is Container &&
      w.decoration is BoxDecoration &&
      (w.decoration! as BoxDecoration).shape == BoxShape.circle,
);

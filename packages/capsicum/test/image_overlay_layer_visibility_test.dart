import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:capsicum/src/ui/util/image_overlay_geometry.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/image_editor_harness.dart';

/// #1127（#884-C）: レイヤごとの表示 / 非表示とロック。
///
/// ⚠⚠ **可視フラグを見る箇所は 3 つある** —— プレビューの構築・当たり判定・
/// **書き出しループ**。3 つ目が最も危なく、忘れると**プレビューでは消えているのに
/// 出力画像には出る**（気づくのは投稿した後）。このプロジェクトが繰り返し踏んで
/// いる「層が 1 つ抜ける」形（#1113 と同型）なので、
/// **プレビューと書き出しを別々のテストで固定する。**
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

  late List<ui.Image> issued;
  setUp(() => issued = []);

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

  /// スタンプを [count] 枚（緑 → 赤）重ね、レイヤ一覧を開いた状態にする。
  Future<ImageEditorHarness> open(WidgetTester tester, {int count = 1}) async {
    final harness = await ImageEditorHarness.open(
      tester,
      imageData: basePng,
      stickerSource: stickerSource(),
    );
    for (var i = 0; i < count; i++) {
      await harness.addSticker();
    }
    await harness.openLayers();
    return harness;
  }

  group('表示 / 非表示 (#1127)', () {
    testWidgets('隠すとプレビューから消える', (tester) async {
      final harness = await open(tester);
      expect(harness.canvasStickers(issued), [issued[0]]);

      await _hide(harness, 0);
      expect(harness.canvasStickers(issued), isEmpty);
    });

    testWidgets('⚠⚠ 隠すと書き出しにも出ない（プレビューだけ消えて画に残らない）', (tester) async {
      final harness = await open(tester);
      await _hide(harness, 0);

      final png = await harness.exportDecoded();
      expect(
        png.at(80, 80),
        base,
        reason: '隠したレイヤの位置が元画像の色のまま＝書き出しループも可視を見ている',
      );
      expect(png.countNear(green), 0, reason: '緑が 1 画素も残っていない');
    });

    testWidgets('隠しても一覧には残り、戻せば書き出しに復帰する', (tester) async {
      final harness = await open(tester);
      await _hide(harness, 0);
      expect(harness.layerTiles, findsOneWidget, reason: '行ごと消すと戻し方が分からなくなる');

      await _show(harness, 0);
      final png = await harness.exportDecoded();
      expect(png.at(80, 80), green);
    });

    testWidgets('隠すのは 1 枚だけ（他のレイヤは書き出しに残る）', (tester) async {
      final harness = await open(tester, count: 2);
      // 一覧は最前面が先頭。先頭＝赤（2 枚目）を隠す。
      await _hide(harness, 0);

      final png = await harness.exportDecoded();
      expect(png.at(80, 80), green, reason: '下の緑が見えるようになる');
      expect(png.countNear(red), 0, reason: '隠した赤は 1 画素も出ない');
    });

    testWidgets('⚠ 全レイヤを非表示にしても書き出しが落ちない', (tester) async {
      final harness = await open(tester, count: 2);
      await _hide(harness, 0);
      await _hide(harness, 1);
      expect(harness.canvasStickers(issued), isEmpty);

      final png = await harness.exportDecoded();
      expect(png.width, 160);
      expect(png.at(80, 80), base);
      expect(png.countNear(green) + png.countNear(red), 0);
    });
  });

  group('ロック (#1127)', () {
    testWidgets('ロック中はキャンバスでドラッグしても動かない', (tester) async {
      final harness = await open(tester);
      final before = tester.getRect(harness.canvasSticker(issued[0]));

      await _lock(harness, 0);
      await tester.drag(harness.canvasSticker(issued[0]), const Offset(80, 60));
      await harness.settle();

      expect(tester.getRect(harness.canvasSticker(issued[0])), before);
    });

    // ⚠ **上のテストだけだと「ドラッグ自体が効いていない」でも緑になる。**
    // ロックを外せば同じ操作で動くことを対で固定する。
    testWidgets('ロックを外せば同じドラッグで動く', (tester) async {
      final harness = await open(tester);
      final before = tester.getRect(harness.canvasSticker(issued[0]));

      await _lock(harness, 0);
      await _unlock(harness, 0);
      await tester.drag(harness.canvasSticker(issued[0]), const Offset(80, 60));
      await harness.settle();

      expect(
        tester.getRect(harness.canvasSticker(issued[0])),
        isNot(before),
        reason: 'ロック解除後は動く（＝上のテストは操作が効かないせいで緑ではない）',
      );
    });

    testWidgets('ロック中はキャンバスをタップしても選ばれない', (tester) async {
      final harness = await open(tester, count: 2);
      // 赤（最前面）を脇へどけ、緑を単独で叩ける状態にする。
      await tester.drag(
        harness.canvasSticker(issued[1]),
        const Offset(-600, -600),
      );
      await harness.settle();

      // いま選ばれているのは赤（最後に足した側）。緑をロックする。
      expect(_selectedTileIndex(harness), 0);
      await _lock(harness, 1);

      await tester.tap(harness.canvasSticker(issued[0]));
      await harness.settle();
      expect(_selectedTileIndex(harness), isNot(1), reason: 'ロック中の緑はタップで選べない');
      // ⚠ **ロック中はポインタを通す**ので、その下に何も無ければ「余白を叩いた」のと
      // 同じ扱いになり、選択は外れる（赤のまま残りはしない）。下にレイヤがあれば
      // そちらが選ばれる（次のテスト）。
      expect(_selectedTileIndex(harness), -1, reason: '余白タップと同じ＝選択解除');

      await _unlock(harness, 1);
      await tester.tap(harness.canvasSticker(issued[0]));
      await harness.settle();
      expect(_selectedTileIndex(harness), 1, reason: 'ロックを外せば選べる');
    });

    testWidgets('ロックしたレイヤは下のレイヤのタップを塞がない', (tester) async {
      final harness = await open(tester, count: 2);
      // 2 枚は完全に重なっている。前面（赤）をロックする。
      await _lock(harness, 0);

      await tester.tap(harness.canvasSticker(issued[1]));
      await harness.settle();
      expect(_selectedTileIndex(harness), 1, reason: 'ロックした赤を素通りして、下の緑が選ばれる');
    });

    testWidgets('ロック中は一覧からもツールバーからも削除できない', (tester) async {
      final harness = await open(tester);
      await _lock(harness, 0);

      expect(
        _iconButton(tester, 'このレイヤーを削除').onPressed,
        isNull,
        reason: '一覧の削除が無効',
      );
      expect(
        _iconButton(tester, '削除').onPressed,
        isNull,
        reason: 'ツールバーの削除も無効（導線が 2 つあるので両方見る）',
      );

      await tester.tap(find.byTooltip('このレイヤーを削除'));
      await tester.pumpAndSettle();
      expect(harness.layerTiles, findsOneWidget, reason: '押しても消えない');
      expect(find.text('元に戻す'), findsNothing, reason: '削除自体が起きていない');
    });

    testWidgets('ロック中は文字レイヤの「テキストを編集」も無効', (tester) async {
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        stickerSource: stickerSource(),
      );
      await harness.addText('ロックされた文字');
      await harness.openLayers();
      expect(
        _iconButton(tester, 'テキストを編集').onPressed,
        isNotNull,
        reason: 'ロック前は押せる',
      );

      await _lock(harness, 0);
      expect(_iconButton(tester, 'テキストを編集').onPressed, isNull);
      expect(_iconButton(tester, '削除').onPressed, isNull);
    });

    testWidgets('ロック中は大きさ・角度・テキスト編集が効かない', (tester) async {
      final harness = await open(tester);
      await _lock(harness, 0);

      expect(
        tester.widget<Slider>(find.byKey(overlaySizeSliderKey)).onChanged,
        isNull,
      );
      expect(
        tester.widget<Slider>(find.byKey(overlayAngleSliderKey)).onChanged,
        isNull,
      );

      await _unlock(harness, 0);
      expect(
        tester.widget<Slider>(find.byKey(overlaySizeSliderKey)).onChanged,
        isNotNull,
        reason: 'ロックを外せば戻る',
      );
      // 書き出しまで通ることも見ておく（無効化でツリーが壊れていない）。
      final png = await harness.exportDecoded();
      expect(png.at(80, 80), green);
    });

    testWidgets('ロックしても重ね順は入れ替えられる', (tester) async {
      final harness = await open(tester, count: 2);
      await _lock(harness, 0); // 最前面の赤をロック

      final list = tester.widget<ReorderableListView>(
        find.byKey(overlayLayerListKey),
      );
      list.onReorderItem!(0, 1);
      await tester.pumpAndSettle();

      final png = await harness.exportDecoded();
      expect(
        png.at(80, 80),
        green,
        reason: '重ね順は列の並びでレイヤ自身の属性ではないので、ロックの対象にしない',
      );
    });
  });
}

/// 一覧の [index] 行目（上が最前面）のトグルを押す。
Future<void> _hide(ImageEditorHarness h, int index) =>
    _tapToggle(h, 'このレイヤーを隠す', index);

Future<void> _show(ImageEditorHarness h, int index) =>
    _tapToggle(h, 'このレイヤーを表示する', index);

Future<void> _lock(ImageEditorHarness h, int index) =>
    _tapToggle(h, 'このレイヤーをロックする', index);

Future<void> _unlock(ImageEditorHarness h, int index) =>
    _tapToggle(h, 'ロックを解除する', index);

/// ⚠⚠ **行で絞ってから tooltip を探す。**`find.byTooltip(...).at(index)` だと
/// **その文言を持つボタンだけを数えた並び**を指すので、1 行目を隠した後の
/// `.at(1)` は「2 行目」ではなく範囲外になる（tooltip は状態で変わるため）。
///
/// ⚠ tooltip が状態で変わること自体は利点で、**探す文言が「いまどちらの状態か」の
/// 検査を兼ねる**（隠した行をもう一度「隠す」ことはできない）。
Future<void> _tapToggle(ImageEditorHarness h, String tooltip, int index) async {
  final button = find.descendant(
    of: h.layerTiles.at(index),
    matching: find.byTooltip(tooltip),
  );
  expect(
    button,
    findsOneWidget,
    reason: '$index 行目に「$tooltip」のボタンが無い（状態が期待と違う）',
  );
  await h.tester.tap(button);
  await h.tester.pumpAndSettle();
}

/// tooltip で名指しした [IconButton]。
///
/// ⚠ **`find.byTooltip` が返すのはツールチップ本体**で、`IconButton` ではない。
/// `IconButton` は `tooltip:` を受け取ると中身をツールチップで包むので、
/// **祖先**をたどって取る。
IconButton _iconButton(WidgetTester tester, String tooltip) => tester.widget(
  find
      .ancestor(of: find.byTooltip(tooltip), matching: find.byType(IconButton))
      .first,
);

/// 一覧の中で選択されている行の位置（上が最前面）。
int _selectedTileIndex(ImageEditorHarness harness) => harness.tester
    .widgetList<ListTile>(harness.layerTiles)
    .toList()
    .indexWhere((t) => t.selected);

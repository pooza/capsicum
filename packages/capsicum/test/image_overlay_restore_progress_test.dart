import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:capsicum/src/model/image_overlay_layer.dart';
import 'package:capsicum/src/service/sticker_source.dart';
import 'package:capsicum/src/ui/screen/image_overlay_screen.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/image_editor_harness.dart';

/// #1238: 前回のレイヤを取り直している間の見せ方と、途中で閉じたときの解放。
///
/// スタンプは 1 枚ずつ URL から取り直すので、回線が遅いと読み込み表示が続く。
/// - 2 枚以上あるときは進み具合（n / m）を出す
/// - ⚠⚠ 途中で画面を閉じたら、**それまでに読んだ画像もすべて解放する**。直す前は
///   「いま読み終えた 1 枚」だけを解放して抜けており、先に読んだぶんが残っていた
void main() {
  late Uint8List basePng;
  late ui.Image stamp;

  setUpAll(() async {
    basePng = await solidPng(160, 160, const Color(0xFF0000FF));
    stamp = await solidImage(16, 16, const Color(0xFFFF0000));
  });

  StickerOverlayLayerSpec sticker(String code) => StickerOverlayLayerSpec(
    shortcode: code,
    url: 'https://example.invalid/$code.png',
    nx: 0.5,
    ny: 0.5,
    sizeFrac: 0.2,
    angle: 0,
    opacity: 1,
    visible: true,
    locked: false,
  );

  testWidgets('2 枚以上の取り直しでは、進み具合を出す', (tester) async {
    final source = _GatedStickerSource(() => stamp.clone());
    await ImageEditorHarness.open(
      tester,
      imageData: basePng,
      stickerSource: source,
      initialLayers: [sticker('a'), sticker('b'), sticker('c')],
    );
    expect(source.gates, hasLength(1), reason: '1 枚ずつ直列に取りに行く');
    expect(find.textContaining('レイヤーを読み込んでいます'), findsNothing);

    source.release(0);
    await tester.pump();
    await tester.pump();
    expect(find.text('レイヤーを読み込んでいます（1 / 3）'), findsOneWidget);

    source.release(1);
    await tester.pump();
    await tester.pump();
    expect(find.text('レイヤーを読み込んでいます（2 / 3）'), findsOneWidget);

    source.release(2);
    await tester.pump();
    await tester.pump();
    expect(
      find.textContaining('レイヤーを読み込んでいます'),
      findsNothing,
      reason: '戻し終えたら消える',
    );
    expect(find.text('完了'), findsOneWidget);
  });

  testWidgets('1 枚だけなら数字を出さない', (tester) async {
    final source = _GatedStickerSource(() => stamp.clone());
    await ImageEditorHarness.open(
      tester,
      imageData: basePng,
      stickerSource: source,
      initialLayers: [sticker('a')],
    );
    expect(find.textContaining('レイヤーを読み込んでいます'), findsNothing);
    source.release(0);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('レイヤーを読み込んでいます'), findsNothing);
    expect(find.text('完了'), findsOneWidget);
  });

  testWidgets('⚠⚠ 途中で閉じたら、それまでに読んだ画像もすべて解放する', (tester) async {
    final source = _GatedStickerSource(() => stamp.clone());
    await ImageEditorHarness.open(
      tester,
      imageData: basePng,
      stickerSource: source,
      initialLayers: [sticker('a'), sticker('b'), sticker('c')],
    );
    source.release(0);
    await tester.pump();
    await tester.pump();
    expect(source.gates, hasLength(2), reason: '2 枚目を待っている');
    expect(source.handed[0].debugDisposed, isFalse, reason: '前提: まだ持っている');

    // 2 枚目を待っている間に画面を閉じる。
    Navigator.of(tester.element(find.byType(ImageOverlayScreen))).pop();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(
      find.byType(ImageOverlayScreen),
      findsNothing,
      reason: '前提: 画面は閉じている（閉じていないと下の検査が空振りする）',
    );

    source.release(1);
    await tester.pump();
    await tester.pump();

    expect(source.handed[1].debugDisposed, isTrue, reason: 'いま読み終えた 1 枚');
    expect(
      source.handed[0].debugDisposed,
      isTrue,
      reason: '⚠ 先に読み終えていたぶん。直す前はここが残っていた',
    );
    expect(source.gates, hasLength(2), reason: '閉じたあとは 3 枚目を取りに行かない');
  });
}

/// `load` を 1 回ずつ手で通す [StickerSource]。
class _GatedStickerSource implements StickerSource {
  _GatedStickerSource(this._build);

  final ui.Image Function() _build;

  /// `load` が呼ばれた順の関門。
  final gates = <Completer<ui.Image>>[];

  /// 画面へ渡した画像（渡した順）。
  final handed = <ui.Image>[];

  void release(int index) {
    final image = _build();
    handed.add(image);
    gates[index].complete(image);
  }

  @override
  Future<CustomEmoji?> pick({
    required BuildContext context,
    required WidgetRef ref,
  }) async => null;

  @override
  Future<ui.Image> load(String url) {
    final gate = Completer<ui.Image>();
    gates.add(gate);
    return gate.future;
  }
}

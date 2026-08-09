import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:capsicum/src/ui/screen/image_overlay_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// #953-3 の回帰テスト。
///
/// v1.53 までは `TextButton.icon` 1 個だった行に #883 が 2 個目（「スタンプを
/// 追加」）を足したが、`Row` のままだったので狭幅・大きめの文字サイズで
/// RenderFlex overflow していた。修正時の実測は **320 論理 px で 9.4px、
/// テキストスケール 1.15 で 32px、1.3 で 54px**。
///
/// overflow は描画時に赤縞が出るだけでレイアウト自体は通ってしまうため、
/// **`tester.takeException()` で FlutterError を拾う**形で固定する。
void main() {
  late Uint8List png;

  setUpAll(() async {
    png = await _solidPng(8, 8);
  });

  Future<void> pumpAt(
    WidgetTester tester, {
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
    // `_decode()` は本物のコーデックを回すので、fake async のままでは完了しない。
    // また読み込み中は `CircularProgressIndicator` が回り続けるため
    // `pumpAndSettle` は必ずタイムアウトする。runAsync で実時間を進めてから
    // 手で pump する。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump();
  }

  group('画像オーバーレイの追加ツールバー (#953-3)', () {
    testWidgets('320px 幅で overflow しない', (tester) async {
      await pumpAt(tester, width: 320, textScale: 1.0);
      expect(find.text('テキストを追加'), findsOneWidget);
      expect(find.text('スタンプを追加'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('320px 幅 + テキストスケール 1.3 でも overflow しない', (tester) async {
      await pumpAt(tester, width: 320, textScale: 1.3);
      expect(tester.takeException(), isNull);
    });

    testWidgets('375px 幅 + テキストスケール 1.35 でも overflow しない', (tester) async {
      await pumpAt(tester, width: 375, textScale: 1.35);
      expect(tester.takeException(), isNull);
    });

    testWidgets('入る幅では 1 行のまま（折り返しても縦積みにしない）', (tester) async {
      await pumpAt(tester, width: 600, textScale: 1.0);
      final text = tester.getTopLeft(find.text('テキストを追加'));
      final sticker = tester.getTopLeft(find.text('スタンプを追加'));
      expect(text.dy, equals(sticker.dy));
      expect(tester.takeException(), isNull);
    });
  });
}

/// テスト用の最小 PNG。`ImageOverlayScreen` は入力バイト列を実際にデコードする
/// ので、ダミーのバイト列ではなく本物を作る。
Future<Uint8List> _solidPng(int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFF884422),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  image.dispose();
  return data!.buffer.asUint8List();
}

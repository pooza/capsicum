/// 画像編集フロー（添付 → 重ねる → 書き出し）をウィジェットテストから端から端まで
/// 動かすための土台 (#947)。
///
/// ## なぜ integration_test でないのか
///
/// この経路で人手確認に落ちていたのは「合成結果が正しいか」だが、それは
/// **`tester.runAsync()` さえ使えば通常のウィジェットテストで検証できる**。
/// `PictureRecorder` → `toImage` → PNG エンコード → デコード → ピクセル取り出しの
/// 全段が動く（実測 2026-08-13）。integration_test を入れると実プラットフォーム
/// チャネルまで届くが、ログイン状態の用意・実サーバーの切り離し・macOS runner の
/// コストが要る割に、埋まる穴はここより狭い。
///
/// ## runAsync の罠（この土台の存在理由）
///
/// `flutter_test` の既定は擬似非同期で、**実 I/O（画像コーデック）を進めない**。
/// そのため `runAsync` 無しで画像デコードや `toImage` を待つと**ハングする**
/// （`pumpAndSettle` はローディング表示が回り続けるので必ずタイムアウトする）。
/// この土台はその作法を内側に閉じ込めているので、利用側は意識しなくてよい。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:capsicum/src/service/sticker_source.dart';
import 'package:capsicum/src/ui/screen/image_overlay_screen.dart';
import 'package:capsicum/src/ui/util/image_overlay_geometry.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 単色 PNG を作る。テスト用の元画像・スタンプ素材の両方に使う。
///
/// ⚠ **`testWidgets` の本体から直接呼んではいけない。** 中で `toImage` を待つが、
/// `testWidgets` の中は擬似非同期なので実 I/O が進まず**ハングする**（エラーには
/// ならないので、テストが黙って止まったらこれを疑う）。素材は `setUpAll` で作るか、
/// `tester.runAsync` の中で作ること。
Future<Uint8List> solidPng(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

/// 単色画像を [ui.Image] で作る。スタンプ素材の差し替えに使う。
///
/// ⚠ [solidPng] と同じ理由で `testWidgets` の本体からは呼べない。`setUpAll` で
/// 1 枚作っておき、[FakeStickerSource] には `clone()` を返させるのが定石
/// （画面側が dispose するので、使い回すと 2 回目以降が死んだ画像になる）。
Future<ui.Image> solidImage(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

/// 実アカウント・実ネットワークの代わりに、決め打ちの素材を返す [StickerSource]。
///
/// [emoji] が null なら「ピッカーをキャンセルした」になる。[imageBuilder] は
/// 呼ばれるたびに**新しいハンドル**を返すこと（画面側が dispose するため）。
/// `setUpAll` で作った 1 枚を `clone()` して返すのが定石。**ここで新規に
/// `toImage` を回してはいけない**——`load` は画面側（＝擬似非同期）から
/// 呼ばれるので完了せずハングする。
class FakeStickerSource implements StickerSource {
  FakeStickerSource({required this.emoji, required this.imageBuilder});

  final CustomEmoji? emoji;
  final ui.Image Function() imageBuilder;

  /// 素材取得が要求された回数。連打ガードの検証に使う。
  int loadCount = 0;

  @override
  Future<CustomEmoji?> pick({
    required BuildContext context,
    required WidgetRef ref,
  }) async => emoji;

  @override
  Future<ui.Image> load(String url) async {
    loadCount++;
    return imageBuilder();
  }
}

/// 画像オーバーレイ画面を立ち上げ、書き出し結果を受け取れる形で保持する。
class ImageEditorHarness {
  ImageEditorHarness._(this.tester);

  final WidgetTester tester;

  /// 「完了」で返ってきた PNG バイト列。キャンセルなら null のまま。
  Uint8List? exported;

  /// 画面を閉じたか（完了・キャンセルを問わず）。
  bool closed = false;

  /// 画面を立ち上げて、元画像のデコード完了まで進める。
  static Future<ImageEditorHarness> open(
    WidgetTester tester, {
    required Uint8List imageData,
    StickerSource? stickerSource,
    Size surfaceSize = const Size(800, 1000),
  }) async {
    final harness = ImageEditorHarness._(tester);
    tester.view.physicalSize = surfaceSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 同じテスト内で開き直すとき、前のツリーが残っていると `find.text` が
    // 二重に当たって tap が「対象が複数」で落ちる。空のツリーを挟んで畳む。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (stickerSource != null)
            stickerSourceProvider.overrideWithValue(stickerSource),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    final result = await Navigator.of(context).push<Uint8List>(
                      MaterialPageRoute(
                        builder: (_) =>
                            ImageOverlayScreen(imageData: imageData),
                      ),
                    );
                    harness
                      ..exported = result
                      ..closed = true;
                  },
                  child: const Text('開く'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('開く'));
    await harness.settle();
    return harness;
  }

  /// 直前の操作を実行し、実 I/O（画像コーデック）を進めてから描画を追いつかせる。
  ///
  /// **順序が重要**。先に `runAsync` してしまうと、route がまだ構築されておらず
  /// `initState` の `_decode` が始まってすらいないタイミングで実時間だけ進める
  /// ことになり、いつまでも画面が出てこない。
  ///
  /// 1. `pump` — 直前の操作をフレームに乗せる（route の構築・`_decode` の開始・
  ///    `_render` の起動はここで走る）
  /// 2. `pump(400ms)` — 画面遷移アニメーションを終わらせる
  /// 3. `runAsync` — 擬似時間では進まない実 I/O をここで進める
  /// 4. `pump` ×2 — 完了した Future の続きを描画へ反映する
  ///
  /// `pumpAndSettle` は使えない。デコード中は `CircularProgressIndicator` が
  /// 回り続けるため必ずタイムアウトする。
  Future<void> settle([
    Duration duration = const Duration(milliseconds: 100),
  ]) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() => Future<void>.delayed(duration));
    await tester.pump();
    await tester.pump();
  }

  /// 「スタンプを追加」を押す（素材は [FakeStickerSource] が返す）。
  Future<void> addSticker() async {
    await tester.tap(find.text('スタンプを追加'));
    await settle();
  }

  /// 「テキストを追加」を押し、ダイアログに [text] を入れて確定する。
  Future<void> addText(String text) async {
    await tester.tap(find.text('テキストを追加'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.text('OK'));
    await settle();
  }

  /// 選択中レイヤの大きさスライダーを動かす。[value] は 0..1 の割合。
  Future<void> setSize(double value) =>
      _dragSlider(overlaySizeSliderKey, value);

  /// 選択中レイヤの回転スライダーを動かす (#946)。[value] は 0..1 の割合で、
  /// 0.5 が無回転。度数で指定したいときは [setAngleDegrees]。
  Future<void> setAngle(double value) =>
      _dragSlider(overlayAngleSliderKey, value);

  /// 回転スライダーを度数で動かす (#946)。-180..180。
  Future<void> setAngleDegrees(double degrees) =>
      setAngle((degrees + 180) / 360);

  /// 「角度をリセット」を押す (#946)。
  Future<void> resetAngle() async {
    await tester.tap(find.byTooltip('角度をリセット'));
    await tester.pump();
  }

  /// ⚠ **キーで名指しする。** スライダは大きさと回転の 2 本あり、
  /// `find.byType(Slider)` では取り違える。
  Future<void> _dragSlider(Key key, double value) async {
    final slider = find.byKey(key);
    expect(slider, findsOneWidget, reason: 'レイヤ未選択だとスライダーが出ない');
    final widget = tester.widget<Slider>(slider);
    widget.onChanged!(widget.min + (widget.max - widget.min) * value);
    await tester.pump();
  }

  /// 「完了」を押して書き出す。戻り値は合成された PNG。
  ///
  /// 書き出しは「実 I/O（合成 → PNG 化）→ pop → 遷移アニメーション → 呼び出し元の
  /// `push` future が解決」と段が多く、1 回の [settle] では届かない。実時間と
  /// 擬似時間を交互に進めながら結果が返るのを待つ。
  Future<Uint8List> export() async {
    await tester.tap(find.text('完了'));
    await settle(const Duration(milliseconds: 300));

    for (var i = 0; i < 20 && exported == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 合成に失敗すると画面は閉じずスナックバーが出る。「返ってこない」より
    // 「失敗した」のほうが原因に近いので、そちらを先に報告する。
    expect(
      find.text('画像の書き出しに失敗しました'),
      findsNothing,
      reason: '合成が失敗している（画面が閉じずエラー表示になった）',
    );
    expect(exported, isNotNull, reason: '書き出しが返ってこない');
    return exported!;
  }

  /// 書き出してピクセルを読める形まで持っていく。デコードも実 I/O なので
  /// `runAsync` の中で回す必要があり、その作法をここに閉じ込める。
  Future<DecodedPng> exportDecoded() async {
    final bytes = await export();
    return decodePng(bytes);
  }

  /// 書き出し済みバイト列（未書き出しなら null）をデコードする。
  Future<DecodedPng> decodePng(Uint8List bytes) async {
    final decoded = await tester.runAsync(() => DecodedPng.decode(bytes));
    return decoded!;
  }
}

/// PNG を復号してピクセルを読めるようにする。
class DecodedPng {
  DecodedPng._(this.width, this.height, this._pixels);

  final int width;
  final int height;
  final Uint32List _pixels;

  static Future<DecodedPng> decode(Uint8List png) async {
    final codec = await ui.instantiateImageCodec(png);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        return DecodedPng._(
          image.width,
          image.height,
          raw!.buffer.asUint32List(),
        );
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  /// 指定座標の色。`rawRgba` はリトルエンディアンの 0xAABBGGRR で入るので、
  /// [Color] の 0xAARRGGBB へ並べ替えて返す。
  Color at(int x, int y) {
    final v = _pixels[y * width + x];
    final a = (v >> 24) & 0xFF;
    final b = (v >> 16) & 0xFF;
    final g = (v >> 8) & 0xFF;
    final r = v & 0xFF;
    return Color.fromARGB(a, r, g, b);
  }

  /// [color] に十分近いピクセルの数。アンチエイリアスの縁を拾わないよう、
  /// 各チャンネル [tolerance] 以内を同色とみなす。
  int countNear(Color color, {int tolerance = 24}) {
    var found = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final p = at(x, y);
        if ((p.a * 255).round() < 128) continue;
        if ((((p.r - color.r) * 255).abs()) <= tolerance &&
            (((p.g - color.g) * 255).abs()) <= tolerance &&
            (((p.b - color.b) * 255).abs()) <= tolerance) {
          found++;
        }
      }
    }
    return found;
  }
}

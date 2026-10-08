import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:capsicum/src/model/image_overlay_layer.dart';
import 'package:capsicum/src/ui/util/image_overlay_geometry.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/image_editor_harness.dart';

/// #1178: 端末の任意の画像をレイヤとして重ねる。
///
/// ## スタンプ (#883) と何が違うか
///
/// 描き方は**同じ経路**（`_ImageBackedOverlayItem` / `_paintImageLayer`）。違うのは
/// **素材の持ち方だけ**:
///
/// | | スタンプ | 端末の画像 |
/// | --- | --- | --- |
/// | 控え | サーバーの URL（取り直せる） | ⚠⚠ **縮小済みの複製のパス**（取り直す先が無い） |
/// | 失効 | 絵文字が消えたとき | **OS が一時領域を掃除したとき**（日常的に起きる） |
///
/// ⚠⚠ **したがって「復元できなかった」は例外ではなく通常運転。**1 枚落ちても
/// 他のレイヤは戻し、落ちた数を利用者へ伝えることが完了条件に入っている。
void main() {
  const base = Color(0xFF102030);
  const photo = Color(0xFFEE2211);

  late Uint8List basePng;
  late ui.Image photoMaster;

  setUpAll(() async {
    basePng = await solidPng(200, 200, base);
    photoMaster = await solidImage(80, 40, photo);
  });

  tearDownAll(() => photoMaster.dispose());

  late List<ui.Image> issued;
  setUp(() => issued = []);

  FakePictureLayerSource source({
    Object? loadError,
    Set<String> missingPaths = const <String>{},
    String path = '/tmp/fake/overlay_picture_1_photo.png',
    String name = 'photo.png',
    bool cancelled = false,
  }) => FakePictureLayerSource(
    file: cancelled ? null : XFile(path),
    loadError: loadError,
    missingPaths: missingPaths,
    path: path,
    name: name,
    imageBuilder: () {
      final image = photoMaster.clone();
      issued.add(image);
      return image;
    },
  );

  group('端末の画像をレイヤとして足す (#1178)', () {
    testWidgets('「画像を追加」でキャンバスに載り、書き出しにも焼き込まれる', (tester) async {
      final picker = source();
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        pictureSource: picker,
      );
      await harness.addPicture();

      expect(picker.loadCount, 1);
      expect(
        harness.canvasStickers(issued),
        hasLength(1),
        reason: 'キャンバスに素材が 1 枚載る',
      );

      final png = await harness.exportDecoded();
      expect(png.width, 200, reason: '元画像の寸法は変わらない');
      // ⚠ **書き出しにも出ていることを見る。**プレビューに載っただけでは
      // 「隠したはずのレイヤが出力に出る / 出ない」系の取りこぼしが拾えない。
      expect(
        png.countNear(photo),
        greaterThan(0),
        reason: '焼き込まれた画像レイヤの色が出力に出ている',
      );
    });

    testWidgets('完了すると記述が PictureOverlayLayerSpec で返る', (tester) async {
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        pictureSource: source(path: '/tmp/fake/copy.png', name: 'ゴメちゃん.jpg'),
      );
      await harness.addPicture();
      await harness.export();

      final layers = harness.exportedLayers;
      expect(layers, hasLength(1));
      final spec = layers!.single;
      expect(spec, isA<PictureOverlayLayerSpec>());
      final picture = spec as PictureOverlayLayerSpec;
      // ⚠⚠ **控えのパスが載っていることが再編集の前提。**ここが空だと、次に
      // 開いたときレイヤが黙って落ちる（しかも初回の編集では気づけない）。
      expect(picture.path, '/tmp/fake/copy.png');
      expect(picture.name, 'ゴメちゃん.jpg');
      expect(
        picture.sizeFrac,
        kOverlayDefaultPictureSizeFrac,
        reason: '⚠ 既定はスタンプ (0.2) より大きい —— 端末の画像はそれ自体を見せたい絵',
      );
    });

    testWidgets('⚠ 大きさの上限はスタンプと同じ 0.8（別の定数で持っている）', (tester) async {
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        pictureSource: source(),
      );
      await harness.addPicture();

      final slider = tester.widget<Slider>(find.byKey(overlaySizeSliderKey));
      expect(slider.max, kOverlayMaxPictureSizeFrac);
      // ⚠ 値は同じでも根拠が別（デコード上限と対）。**文字の上限には落ちていない**
      // ことを見る —— ここを取り違えると、画像が 0.25 までしか伸びなくなる。
      expect(slider.max, isNot(kOverlayMaxTextSizeFrac));
    });

    testWidgets('ピッカーをキャンセルすると何も足さない', (tester) async {
      final picker = source(cancelled: true);
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        pictureSource: picker,
      );
      await harness.addPicture();

      expect(picker.loadCount, 0, reason: 'キャンセルなら素材を取りに行かない');
      expect(harness.canvasStickers(issued), isEmpty);
      // ⚠ レイヤが 0 のままなら、選択中レイヤの操作行は出ない。
      expect(find.byKey(overlaySizeSliderKey), findsNothing);
    });
  });

  group('⚠ 控えが失効したときの振る舞い (#1178)', () {
    PictureOverlayLayerSpec specAt(String path, String name) =>
        PictureOverlayLayerSpec(
          path: path,
          name: name,
          nx: 0.5,
          ny: 0.5,
          sizeFrac: 0.3,
          angle: 0,
          opacity: 1,
          visible: true,
          locked: false,
        );

    testWidgets('控えが残っていれば再編集で戻る', (tester) async {
      final picker = source();
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        pictureSource: picker,
        initialLayers: [specAt('/tmp/fake/kept.png', 'kept.png')],
      );

      expect(picker.restoreCount, 1);
      expect(harness.canvasStickers(issued), hasLength(1));
      expect(find.text('レイヤーを 1 個復元できませんでした（このまま完了すると画像から外れます）'), findsNothing);

      await harness.openLayers();
      expect(
        find.descendant(
          of: harness.layerTiles.first,
          matching: find.text('kept.png'),
        ),
        findsOneWidget,
        reason: '一覧の見出しはファイル名',
      );
    });

    testWidgets('⚠⚠ 控えが消えていたらそのレイヤだけ落とし、他は残して数を伝える', (tester) async {
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        pictureSource: source(missingPaths: {'/tmp/fake/gone.png'}),
        initialLayers: [
          specAt('/tmp/fake/gone.png', 'gone.png'),
          specAt('/tmp/fake/kept.png', 'kept.png'),
        ],
      );

      // ⚠ **落ちたのは 1 枚だけ。**全部落とすと「1 枚消えた」ではなく
      // 「編集が丸ごと失われた」になる。
      expect(harness.canvasStickers(issued), hasLength(1));
      // ⚠ **件数は数えない**（`findsOneWidget` にしない）。復元は画面が出てくる途中
      // ＝遷移アニメーション中に終わるので、`ScaffoldMessenger` が**下の画面の
      // Scaffold にも同じ SnackBar を組み立てる**。#1129 のテストと同じ扱い。
      expect(
        find.text('レイヤーを 1 個復元できませんでした（このまま完了すると画像から外れます）'),
        findsWidgets,
        reason: '⚠ 黙って落とすと、開いて完了しただけで画像が消えた絵になる',
      );

      await harness.openLayers();
      expect(harness.layerTiles, findsOneWidget);
      expect(find.text('gone.png'), findsNothing);
    });

    testWidgets('⚠ 文言で種別を名指ししない（スタンプでも画像でも同じ数え方）', (tester) async {
      await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        pictureSource: source(missingPaths: {'/tmp/fake/gone.png'}),
        initialLayers: [specAt('/tmp/fake/gone.png', 'gone.png')],
      );

      // ⚠⚠ 旧文言は「スタンプを N 個…」だった。端末の画像が落ちたときに
      // **嘘になる**ので、種別を名乗らない形へ変えてある。
      expect(find.textContaining('スタンプを 1 個'), findsNothing);
      // ⚠ 上と同じ理由で件数は数えない（下の画面の Scaffold にも組まれる）。
      expect(find.textContaining('レイヤーを 1 個'), findsWidgets);
    });
  });

  group('⚠ 読み込みに失敗したとき (#1178)', () {
    testWidgets('上限超過は専用の文言で伝える', (tester) async {
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        pictureSource: source(
          loadError: const FormatException('picture too large'),
        ),
      );
      await harness.addPicture();

      // ⚠⚠ **「読み込めませんでした」で済ませない。**原因が分からないと、利用者は
      // 同じ画像で何度も試すことになる。
      expect(find.text('この画像は大きすぎて重ねられませんでした'), findsOneWidget);
      expect(find.text('画像を読み込めませんでした'), findsNothing);
      expect(harness.canvasStickers(issued), isEmpty);
    });

    testWidgets('それ以外の失敗は一般の文言にする', (tester) async {
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        pictureSource: source(
          loadError: const FormatException('empty picture'),
        ),
      );
      await harness.addPicture();

      expect(find.text('画像を読み込めませんでした'), findsOneWidget);
      expect(find.text('この画像は大きすぎて重ねられませんでした'), findsNothing);
    });

    testWidgets('⚠ 失敗しても続けて追加できる（ガードが立ったままにならない）', (tester) async {
      // ⚠⚠ `_loadingPicture` を false へ戻し忘れると、**一度失敗したら二度と
      // 画像を足せない画面**になる。押せない見た目のまま無反応になるので、
      // 「壊れている」と読まれる。
      final picker = source(loadError: const FormatException('empty picture'));
      final harness = await ImageEditorHarness.open(
        tester,
        imageData: basePng,
        pictureSource: picker,
      );
      await harness.addPicture();
      expect(picker.loadCount, 1);

      // ⚠ **2 回目を tap で確かめない。**SnackBar は画面下端に出るので、追加行の
      // ボタンに**かぶって tap を奪う**（`loadCount` が 1 のまま増えず、ガードの
      // 検査になっていなかった）。ボタン自身が有効に戻っていることを直接見る。
      final button = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('画像を追加'),
          matching: find.byType(TextButton),
        ),
      );
      expect(
        button.onPressed,
        isNotNull,
        reason: '⚠⚠ ここが null なら、一度失敗したら二度と画像を足せない',
      );
      // 進捗表示も畳まれていること（回り続けると「まだ読み込み中」に見える）。
      expect(
        find.descendant(
          of: find.byType(TextButton),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
    });
  });
}

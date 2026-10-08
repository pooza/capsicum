import 'dart:io';

import 'package:capsicum/src/constants.dart';
import 'package:capsicum/src/service/picture_layer_source.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/image_editor_harness.dart';

/// #1178: 端末の画像を「縮小して取り込み、縮小済みを控える」ところの検査。
///
/// ## なぜここが肝か
///
/// この Issue で**決めることが 1 点だけ残っていた**のが取り込み時の縮小上限で、
/// ここがその実装。⚠⚠ **2 つを同時に満たす必要がある**:
///
/// 1. **原寸を持たない** —— 4032×3024 の写真は 1 枚で約 48MB のピクセル
///    バッファになり、数枚重ねた時点で端末が落ちる
/// 2. **最大まで拡大しても粗が出ない** —— 画像レイヤは元画像の高さの
///    `kOverlayMaxPictureSizeFrac`（0.8）まで伸ばせるので、4K 級（高さ 2160）×0.8
///    ＝ 1728px を上回っていること
///
/// ⚠ **控えも縮小後の実体にする。**元ファイルをコピーすると下書きに写真の原寸が
/// 溜まる（1 枚数 MB × レイヤ数 × 添付数）。
void main() {
  // ⚠ `getTemporaryDirectory` はプラットフォームチャネル越しなので、テストでは
  // 差し替えが要る。`path_provider_platform_interface` を直接 import すると
  // 推移的依存に頼ることになるので、**チャネルを直に差し替える**。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('picture_layer_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async =>
              call.method == 'getTemporaryDirectory' ? tempRoot.path : null,
        );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
  });

  const source = PictureLayerSource();

  /// 指定寸法の PNG を実ファイルとして置き、[XFile] で返す。
  Future<XFile> pngFile(
    int width,
    int height, {
    String name = 'photo.png',
  }) async {
    final bytes = await solidPng(width, height, const Color(0xFF3366CC));
    // ⚠ OS の区切りで組む (#1168)。`XFile.name` は `Platform.pathSeparator`
    // でしか切らないので、Windows で `/` を混ぜると表示名にディレクトリ名が残る。
    // ピッカー由来のパスは OS の区切りなので、本体ではこの形にならない。
    final file = File('${tempRoot.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes, flush: true);
    return XFile(file.path);
  }

  group('取り込み時に縮小する (#1178)', () {
    test('⚠⚠ 上限より高い画像は上限まで縮めて持つ', () async {
      final file = await pngFile(1500, 3000);
      final material = await source.load(file);
      addTearDown(material.image.dispose);

      expect(material.image.height, PictureLayerLimits.maxDecodeHeight);
      // 縦横比が保たれている（幅は指定していない）。
      expect(material.image.width, closeTo(1500 * 2048 / 3000, 2));
    });

    test('⚠ 上限より小さい画像は引き伸ばさない', () async {
      final file = await pngFile(300, 200);
      final material = await source.load(file);
      addTearDown(material.image.dispose);

      // ⚠⚠ `allowUpscaling: false` が効いていること。ここが抜けると、小さな画像が
      // 2048px へ引き伸ばされて**粗いうえにメモリも食う**という最悪の組み合わせに
      // なる（しかも見た目は「ぼやけただけ」なので気づきにくい）。
      expect(material.image.height, 200);
      expect(material.image.width, 300);
    });

    test('⚠⚠ 上限は「最大まで拡大しても粗が出ない」を満たす', () {
      // 4K 級（高さ 2160）の元画像に、上限の比率で貼ったときの実寸。
      const largestDrawnHeight = 2160 * 0.8;
      expect(
        PictureLayerLimits.maxDecodeHeight,
        greaterThan(largestDrawnHeight),
        reason: '⚠ ここが下回ると、スライダーを上げたときに引き伸ばしになる',
      );
    });
  });

  group('控えを残す (#1178)', () {
    test('縮小済みの実体が複製として残り、元ファイルとは別のパスになる', () async {
      final file = await pngFile(1200, 2400);
      final material = await source.load(file);
      addTearDown(material.image.dispose);

      expect(material.path, isNot(file.path), reason: '元ファイルを指していない');
      expect(File(material.path).existsSync(), isTrue);
      expect(material.name, 'photo.png', reason: '表示名は選んだファイル名');

      // ⚠⚠ **控えが「縮小後」であること。**元をコピーしていると下書きに原寸が
      // 溜まるので、**実際にデコードして高さを見る**（バイト数の比較だと、PNG の
      // 圧縮率の差で偶然通ってしまう）。
      final copy = await source.restore(material.path);
      addTearDown(copy.dispose);
      expect(copy.height, PictureLayerLimits.maxDecodeHeight);
      expect(copy.height, lessThan(2400));
    });

    test('⚠ 控えが消えていたら restore が投げる（呼び出し側が数えて伝える）', () async {
      final file = await pngFile(200, 200);
      final material = await source.load(file);
      material.image.dispose();
      await File(material.path).delete();

      await expectLater(
        source.restore(material.path),
        throwsA(isA<FormatException>()),
      );
    });

    test('⚠ ファイル名に使えない文字は控えのパスに持ち込まない', () async {
      // 写真アプリ由来の名前には `/` や `:` が混じることがある。⚠ そのまま連結
      // すると**パスが壊れる**（Windows は `:` も不可）。
      final bytes = await solidPng(50, 50, const Color(0xFF00AA00));
      final material = await source.load(
        XFile.fromData(bytes, name: 'IMG:2026/09/29.heic'),
      );
      addTearDown(material.image.dispose);

      final basename = material.path.split(RegExp(r'[/\\]')).last;
      expect(basename, isNot(contains(':')));
      expect(File(material.path).existsSync(), isTrue);
      expect(
        basename.endsWith('.png'),
        isTrue,
        reason: '控えは PNG で書き出す（元の拡張子を引き継がない）',
      );
    });
  });

  group('⚠ 上限を超えるファイルは弾く (#1178)', () {
    test('申告された長さが上限を超えていれば、読む前に投げる', () async {
      // ⚠⚠ **読んでから弾いても意味が半分無い。**`readAsBytes` まで進むと、弾く
      // 判断をする時点ですでに原寸ぶんメモリに載っている。`XFile.fromData` の
      // `length` は申告値をそのまま返すので、**巨大ファイルを作らずに**この経路を
      // 踏める。
      final bytes = await solidPng(10, 10, const Color(0xFFFFFFFF));
      await expectLater(
        source.load(
          XFile.fromData(
            bytes,
            name: 'huge.png',
            length: PictureLayerLimits.maxBytes + 1,
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'picture too large',
          ),
        ),
      );
    });

    test('⚠ 申告と実体がずれていても、実体側で弾く', () async {
      // 申告を小さく偽った場合。`length` に小さい値を入れると `readAsBytes` まで
      // 進むので、**手元に来た実体でもう一度確かめている**ことを見る。
      final bytes = Uint8List(PictureLayerLimits.maxBytes + 1);
      await expectLater(
        source.load(XFile.fromData(bytes, name: 'lying.png', length: 10)),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'picture too large',
          ),
        ),
      );
    });

    test('中身が空のファイルは投げる', () async {
      await expectLater(
        source.load(XFile.fromData(Uint8List(0), name: 'empty.png')),
        throwsA(isA<FormatException>()),
      );
    });

    test('⚠ 上限は端末の写真が収まる大きさ', () {
      // HEIC 2〜4MB / JPEG 5〜10MB / スクリーンショットの PNG 5MB 前後。⚠ ここを
      // 下げると、**利用者が自分で選んだ普通の写真が載らなくなる**。
      expect(
        PictureLayerLimits.maxBytes,
        greaterThanOrEqualTo(16 * 1024 * 1024),
        reason: '⚠⚠ 端末の写真を弾く高さまで下げない',
      );
    });
  });

  group('デコードできないものは投げる (#1178)', () {
    test('画像でないバイト列', () async {
      final bytes = Uint8List.fromList(List<int>.filled(64, 0x41));
      await expectLater(
        source.load(XFile.fromData(bytes, name: 'notimage.txt')),
        throwsA(anything),
      );
    });
  });
}

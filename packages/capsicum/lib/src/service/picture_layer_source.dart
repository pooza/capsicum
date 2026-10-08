import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cross_file/cross_file.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../constants.dart';
import '../provider/platform_providers.dart';

/// 画像レイヤの素材 1 枚 (#1178)。
///
/// ⚠ **[image] の解放は呼び出し側（編集画面）の責任。**スタンプ
/// （`StickerSource.load`）と同じ作法に揃えてある。
class PictureLayerMaterial {
  const PictureLayerMaterial({
    required this.image,
    required this.path,
    required this.name,
  });

  /// 縮小済みのデコード結果。表示と書き出しで**同じ実体を共有する**。
  final ui.Image image;

  /// [image] と同じ絵を持つ複製の置き場。⚠ **再編集・下書きのための控え。**
  final String path;

  /// 選んだファイルの表示名。
  final String name;
}

/// 端末内の画像をレイヤの素材として調達する経路 (#1178)。
///
/// ⚠⚠ **`StickerSource` と別の口にしてある。**畳めそうに見えるが、素材の性質が
/// 逆向きで、**守っているものが違う**:
///
/// | | スタンプ (`StickerSource`) | 画像レイヤ（ここ） |
/// | --- | --- | --- |
/// | 供給元 | **サーバー由来の任意 URL**（信用できない） | **利用者が選んだ端末内のファイル** |
/// | 上限の理由 | 受け取る量を制限する（防御） | 手元のメモリを守る |
/// | 取り直し | URL から**いつでも取り直せる** | ⚠⚠ **取り直す先が無い** → 複製を控える |
/// | 失敗の意味 | 絵文字が消えた（相手側の変化） | 一時領域が掃除された（手元の事情） |
///
/// 1 つの `load(String)` に畳むと、この「複製を作るかどうか」が呼び出し側の
/// 暗黙の分岐になる。⚠ **控えを作り忘れると、再編集で黙って落ちるレイヤになる**
/// （しかも初回の編集では気づけない）。
///
/// テストからは [pictureLayerSourceProvider] を override して、**端末のピッカーも
/// ファイルシステムも無しに**追加〜書き出し〜復元を端から端まで動かせる。
class PictureLayerSource {
  const PictureLayerSource();

  /// レイヤにする画像を選ばせる。キャンセル時は null。
  Future<XFile?> pick({required WidgetRef ref}) =>
      ref.read(mediaPickerProvider).pickImage();

  /// 選ばれたファイルを読み、**縮小してデコードしたうえで複製を残す**。
  ///
  /// ⚠⚠ **複製は「縮小後」の実体にする。**元のファイルをコピーすると、下書きに
  /// 写真の原寸が溜まる（1 枚で数 MB × レイヤ数 × 添付数）。縮小済みを控えれば
  /// **復元時のデコードも軽くなる**し、控えと `image` の絵が一致する。
  ///
  /// ⚠ 上限を超えるファイルは [FormatException] を投げる。呼び出し側が利用者へ
  /// 伝える（黙って落とすと「自分で選んだ画像が理由なく載らない」に見える）。
  ///
  /// ⚠⚠ **控えは自分では消さない。**レイヤを消した時点で消すと、
  ///
  /// - **削除の取り消し**（`kOverlayUndoWindow` の 5 秒）で戻したレイヤが描けない
  /// - **下書きから開き直したとき**に、まだ生きているはずの控えが無くなっている
  ///
  /// のどちらかを壊す。⚠ **結果として一時領域に溜まる** —— 掃除は OS に委ねており、
  /// これは焼き込み済み PNG（`compose_screen` の `_writeTempPng`）と同じ扱い。
  /// **縮小してから控えているのはこのためでもある**（原寸を溜めない）。
  Future<PictureLayerMaterial> load(XFile file) async {
    // ⚠ **読む前に長さを見る。**`readAsBytes` まで進むと、弾く判断をする時点で
    // すでに原寸ぶんメモリに載っている（弾く意味が半分消える）。
    final declared = await file.length();
    if (declared > PictureLayerLimits.maxBytes) {
      throw const FormatException('picture too large');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw const FormatException('empty picture');
    }
    // `length()` の申告と実体がずれる実装（ストリーム由来の XFile 等）への保険。
    if (bytes.length > PictureLayerLimits.maxBytes) {
      throw const FormatException('picture too large');
    }
    final image = await decode(bytes);
    // ⚠⚠ **控えの書き出しで失敗したら画像も解放して投げ直す。**ここで漏らすと、
    // 「載らなかったのにネイティブメモリだけ増える」形になる。
    try {
      final path = await _persist(image, file.name);
      return PictureLayerMaterial(
        image: image,
        path: path,
        name: file.name.isNotEmpty ? file.name : _basename(path),
      );
    } catch (_) {
      image.dispose();
      rethrow;
    }
  }

  /// 控えから素材を読み直す (#1178)。再編集・下書きの復元で使う。
  ///
  /// ⚠ **控えが消えていれば投げる。**呼び出し側が落として数を伝える。
  Future<ui.Image> restore(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const FormatException('picture copy is gone');
    }
    return decode(await file.readAsBytes());
  }

  /// バイト列を**上限まで縮めて**デコードする。
  ///
  /// ⚠⚠ **`targetHeight` を渡さないと原寸で展開される。**4032×3024 の写真は
  /// 1 枚で約 48MB のピクセルバッファになり、数枚重ねた時点で端末が落ちる。
  /// 幅は指定しない（縦横比が保たれる）。⚠ `allowUpscaling: false` なので、
  /// 上限より小さい画像が引き伸ばされることはない。
  Future<ui.Image> decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetHeight: PictureLayerLimits.maxDecodeHeight,
      allowUpscaling: false,
    );
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }

  /// 縮小済みの実体を一時領域へ PNG で書き出し、そのパスを返す。
  Future<String> _persist(ui.Image image, String originalName) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw const FormatException('failed to encode picture copy');
    }
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final stem = _stemOf(originalName.isNotEmpty ? originalName : 'picture');
    final out = File('${dir.path}/overlay_picture_${stamp}_$stem.png');
    // macOS の一時ディレクトリは実体が未作成のことがあり、`writeAsBytes` は
    // 親ディレクトリを作らないため明示的に作成する（`_writeTempPng` と同じ）。
    await out.create(recursive: true);
    await out.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return out.path;
  }

  static String _stemOf(String name) {
    final base = _basename(name);
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    // ⚠ ファイル名に使えない文字を落とす。写真アプリ由来の名前に `/` や `:` が
    // 入ることがあり、そのまま連結するとパスが壊れる（Windows は `:` も不可）。
    final safe = stem.replaceAll(RegExp(r'[^\w.\-]'), '_');
    return safe.isEmpty ? 'picture' : safe;
  }

  static String _basename(String path) {
    final index = path.lastIndexOf(RegExp(r'[/\\]'));
    return index < 0 ? path : path.substring(index + 1);
  }
}

/// [PictureLayerSource] の差し替え口 (#1178)。
final pictureLayerSourceProvider = Provider<PictureLayerSource>(
  (ref) => const PictureLayerSource(),
);

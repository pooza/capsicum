import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import '../ui/widget/sticker_picker_sheet.dart';

/// スタンプ素材として受け入れるレスポンスボディの上限 (#953-2)。
///
/// 素材の供給元はサーバー由来の任意 URL（`CustomEmoji.url`）で、**サイズを
/// こちらで保証できない**。プリセット 3 サーバーの実データで最大が 1MB 弱
/// （アニメーション webp）なので、桁 1 つぶんの余裕を見て 8MB。カスタム絵文字は
/// 一覧に並べて使うものなので、これを超える素材は運用上そもそも成立しない。
const kMaxStickerBytes = 8 * 1024 * 1024;

/// スタンプ素材をデコードする最大高さ（px、#953-2）。
///
/// スタンプは元画像の高さに対する比率（既定 0.2）で描かれるので、素材が元画像
/// より高精細でも使い道がない。書き出し先はプリセット上限の 4K 級を想定し、
/// その 1/2 を上限にしておけば拡大しても粗が出ない。
const kMaxStickerDecodeHeight = 2048;

/// 画像オーバーレイに載せるスタンプ素材の調達経路 (#883)。
///
/// 「ピッカーで選ばせる」と「選ばれた URL を取ってデコードする」の 2 つを 1 つの
/// 差し替え口にまとめている (#947)。既定の実装は実アカウント・実サーバーを要求
/// するため、テストからは [stickerSourceProvider] を override して**アカウントも
/// ネットワークも無しに**合成〜書き出しを端から端まで動かせるようにする。
///
/// 2 つを別々の provider に割らないのは、テスト側が常に両方を差し替える必要が
/// あるため（素材を選べても取得できなければ載らない）。呼び出し側から見ても
/// 「素材をどこから調達するか」という 1 つの関心事になっている。
class StickerSource {
  const StickerSource();

  /// 素材にするカスタム絵文字を選ばせる。キャンセル時は null。
  Future<CustomEmoji?> pick({
    required BuildContext context,
    required WidgetRef ref,
  }) => showStickerPickerSheet(context: context, ref: ref);

  /// 素材 URL を取得してデコードする。呼び出し側が [ui.Image] の dispose に
  /// 責任を持つ。
  Future<ui.Image> load(String url) => _loadFromNetwork(url);

  Future<ui.Image> _loadFromNetwork(String url) async {
    final response =
        await Dio(
          BaseOptions(
            connectTimeout: kNetworkConnectTimeout,
            receiveTimeout: kNetworkReceiveTimeout,
            // Content-Length が付いていれば、1 バイトも読まずにここで弾ける。
            // 付いていない（chunked）場合は下の onReceiveProgress で見る。
            maxRedirects: 3,
          ),
        ).get<List<int>>(
          url,
          options: Options(responseType: ResponseType.bytes),
          onReceiveProgress: (received, total) {
            if (received > kMaxStickerBytes) {
              throw const FormatException('sticker body too large');
            }
          },
        );
    final contentLength = response.headers.value(Headers.contentLengthHeader);
    final declared = contentLength == null ? null : int.tryParse(contentLength);
    if (declared != null && declared > kMaxStickerBytes) {
      throw const FormatException('sticker body too large');
    }
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException('empty sticker body');
    }
    // onReceiveProgress が呼ばれない実装（レスポンス全体を一括で渡す adapter）
    // でも取りこぼさないよう、手元に来た実体でもう一度確かめる。
    if (bytes.length > kMaxStickerBytes) {
      throw const FormatException('sticker body too large');
    }
    // `targetHeight` を渡してデコード段で縮める。渡さないと 8000x8000 の PNG が
    // 原寸（= 256MB のピクセルバッファ）で展開される。スタンプは元画像の高さの
    // 数割にしか描かれないので、原寸を保持する意味がそもそも無い。
    // 幅は指定しない（アスペクト比が保たれる）。
    final codec = await ui.instantiateImageCodec(
      Uint8List.fromList(bytes),
      targetHeight: kMaxStickerDecodeHeight,
      allowUpscaling: false,
    );
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }
}

/// [StickerSource] の差し替え口 (#947)。
final stickerSourceProvider = Provider<StickerSource>(
  (ref) => const StickerSource(),
);

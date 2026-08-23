import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import '../ui/widget/sticker_picker_sheet.dart';

/// 受け入れ上限の正本は [StickerLimits]（`constants.dart`）へ移した (#976)。
/// `k` 付きトップレベル定数の置き場をそちらへ集約しているため。

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
  ///
  /// **アニメーション絵文字は先頭フレームだけを使う** (#883)。書き出し先が静止
  /// PNG である以上どこかのフレームを選ぶしかなく、プリセット 3 サーバーの実データ
  /// （gif / webp / apng を無作為抽出）で測ったところ、実際にアニメーションする
  /// 絵文字のフレーム 0 はいずれも「全フレーム中の最大被覆」の 6 割以上を占めて
  /// おり、空・スカスカのものは 1 つも無かった。よって「途中のフレームを選ぶ」
  /// ヒューリスティックは持たない（#883 のコメントに実測値）。
  ///
  /// なお **このフレーム選択が実際に効くのは Misskey 系サーバーだけ** (#960)。
  /// Mastodon の `CustomEmoji.url` は `static_url ?? url`（mastodon/extensions.dart
  /// / adapter.dart）で常に静止画が返るため、フレームずれの問題自体が起きない。
  /// 上の実測が「プリセット 3 サーバー」で足りたのは、Mastodon 側は測るまでもなく
  /// 静止画だったから。
  ///
  /// ⚠ **タイムアウトだけでは巨大ボディを止められない** (#953-2)。
  /// `receiveTimeout` は dio 仕様上「受信バイトイベントの間隔」なので、5 秒未満の
  /// 間隔で細く流れ続ける数百 MB のボディは打ち切られない。素材はサーバー由来の
  /// 任意 URL（`CustomEmoji.url`）なので、**総バイト数（[StickerLimits.maxBytes]）と
  /// デコード後の寸法（[StickerLimits.maxDecodeHeight]）の両方に上限を張る**。
  Future<ui.Image> load(String url) => _loadFromNetwork(url);

  Future<ui.Image> _loadFromNetwork(String url) async {
    // 上限超過を見つけたら **受信そのものを打ち切る**。onReceiveProgress は dio の
    // `source.listen` の onData 内（しかもバッファへ add した後）で呼ばれるので、
    // そこで throw しても購読は生きたままで、
    //   - ダウンロードは止まらず、バイト列は無制限に積み上がる
    //   - チャンクごとに zone の uncaught error が上がり、Sentry へ大量に飛ぶ
    // という形になる。CancelToken なら購読ごと切れる。
    final cancelToken = CancelToken();
    var oversized = false;
    final Response<List<int>> response;
    try {
      response =
          await Dio(
            BaseOptions(
              connectTimeout: kNetworkConnectTimeout,
              receiveTimeout: kNetworkReceiveTimeout,
              maxRedirects: 3,
            ),
          ).get<List<int>>(
            url,
            cancelToken: cancelToken,
            options: Options(responseType: ResponseType.bytes),
            onReceiveProgress: (received, total) {
              if (received <= StickerLimits.maxBytes || oversized) return;
              oversized = true;
              cancelToken.cancel('sticker body too large');
            },
          );
    } on DioException {
      if (oversized) throw const FormatException('sticker body too large');
      rethrow;
    }
    // Content-Length の確認は事前弾きにはならない（`get` はボディを全部読み終えて
    // から返る）。chunked で申告と実体がずれる場合の保険として残している。
    final contentLength = response.headers.value(Headers.contentLengthHeader);
    final declared = contentLength == null ? null : int.tryParse(contentLength);
    if (declared != null && declared > StickerLimits.maxBytes) {
      throw const FormatException('sticker body too large');
    }
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException('empty sticker body');
    }
    // onReceiveProgress が呼ばれない実装（レスポンス全体を一括で渡す adapter）
    // でも取りこぼさないよう、手元に来た実体でもう一度確かめる。
    if (bytes.length > StickerLimits.maxBytes) {
      throw const FormatException('sticker body too large');
    }
    // `targetHeight` を渡してデコード段で縮める。渡さないと 8000x8000 の PNG が
    // 原寸（= 256MB のピクセルバッファ）で展開される。スタンプは元画像の高さの
    // 数割にしか描かれないので、原寸を保持する意味がそもそも無い。
    // 幅は指定しない（アスペクト比が保たれる）。
    final codec = await ui.instantiateImageCodec(
      Uint8List.fromList(bytes),
      targetHeight: StickerLimits.maxDecodeHeight,
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

import 'package:capsicum_core/capsicum_core.dart';

import 'now_playing_provider.dart';

/// 複数の [NowPlayingProvider] を **優先順位つきで合成** するリゾルバ (#466)。
///
/// NowPlaying は「OS ごとに 1 実装を選ぶ」既存の factory 抽象
/// （[MediaPicker] 等）とは構造が違う。取得源が 2 軸（OS ネイティブ /
/// Spotify）あり、両方が同時に使えることもあるため、factory ではなく
/// **優先順位リゾルバ**にする（design: docs/nowplaying-design.md）。
///
/// 優先順位は「OAuth 連携済み Spotify > OS ネイティブ API > フォールバック」。
/// Spotify を最優先にするのは、トラック URL を返せる唯一の源だから
/// （URL があれば SNS / モロヘイヤが unfurl でき、整形が不要）。
///
/// [providers] は**優先順位の高い順**に並べて渡す（Spotify 源 → OS ネイティブ源）。
class NowPlayingResolver {
  final List<NowPlayingProvider> _providers;

  const NowPlayingResolver(List<NowPlayingProvider> providers)
    : _providers = providers;

  /// いずれかの源がこの端末 / アカウントで利用可能か。
  ///
  /// compose 画面の「ナウプレを挿入」ボタンを出すかどうかの判定に使う
  /// （どの源も使えないなら、ボタン自体を隠す）。
  bool get hasAvailableSource => _providers.any((p) => p.isAvailable);

  /// 優先順位順に利用可能な源を試し、最初に取得できた [NowPlayingInfo] を返す。
  ///
  /// どの源からも取れなければ null（呼び出し側は「再生中の曲がありません」）。
  /// 個々の provider は例外を投げない契約だが、防御的に try/catch で次の源へ
  /// フォールバックする。
  Future<NowPlayingInfo?> currentlyPlaying() async {
    for (final provider in _providers) {
      if (!provider.isAvailable) continue;
      try {
        final info = await provider.currentlyPlaying();
        if (info != null) return info;
      } catch (_) {
        // この源は諦めて次へ。
      }
    }
    return null;
  }
}

import 'package:capsicum_core/capsicum_core.dart';

import 'now_playing_provider.dart';

/// OS ネイティブな再生情報 pull を持たないプラットフォーム用の no-op 実装。
///
/// macOS / iOS / Android は公開 API で他アプリの再生情報を取得できない、
/// または取得に重い権限が要るため、OS ネイティブ pull は持たない
/// （design §プラットフォーム実装方針）。これらの OS では Spotify 源（pull）
/// と共有インテント（push）でカバーする。
class NoopNowPlayingProvider implements NowPlayingProvider {
  const NoopNowPlayingProvider();

  @override
  bool get isAvailable => false;

  @override
  Future<NowPlayingInfo?> currentlyPlaying() async => null;
}

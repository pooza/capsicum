import 'dart:io' show Platform;

import 'apple_music_now_playing_provider.dart';
import 'mpris_now_playing_provider.dart';
import 'noop_now_playing_provider.dart';
import 'now_playing_provider.dart';
import 'smtc_now_playing_provider.dart';

/// プラットフォームに応じた **OS ネイティブ** [NowPlayingProvider] を生成する。
///
/// [Platform.isXxx] を参照する箇所は `lib/src/platform/` 配下に閉じ込める
/// (CLAUDE.md デスクトップ対応 設計指針)。Spotify 源は OS 非依存なので
/// ここでは扱わず、[NowPlayingResolver] が OS ネイティブ源と合成する。
///
/// 実装状況（design §依存と着手順序）:
/// - Linux  : MPRIS（`dbus` パッケージ）— #466、実装済み
/// - Windows: SMTC（C++/WinRT メソッドチャンネル）— #484、実装済み
/// - iOS    : Apple Music（MPMusicPlayerController メソッドチャンネル）— #668、実装済み
/// - macOS  : Apple Music（ミュージック.app を AppleScript で照会）— #668、実装済み
/// - Android: OS ネイティブ pull なし → no-op
NowPlayingProvider createNativeNowPlayingProvider() {
  if (Platform.isLinux) {
    return const MprisNowPlayingProvider();
  }
  if (Platform.isWindows) {
    return const SmtcNowPlayingProvider();
  }
  if (Platform.isIOS || Platform.isMacOS) {
    return const AppleMusicNowPlayingProvider();
  }
  return const NoopNowPlayingProvider();
}

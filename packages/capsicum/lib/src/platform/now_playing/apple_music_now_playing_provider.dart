import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/services.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'now_playing_provider.dart';

/// iOS / macOS の Apple Music（ミュージック.app）から「現在再生中の曲」を取得する
/// [NowPlayingProvider] 実装 (#668)。
///
/// #466 / nowplaying-design.md では「iOS / macOS は公開 API で他アプリの再生
/// 情報を取れない」としていたが、これは**任意アプリの横断取得**の話。Apple Music
/// に限れば Apple 公認の公開 API で pull でき、App Store でも許可される
/// （private MediaRemote.framework は使わない）:
///
/// - iOS  : `MPMusicPlayerController.systemMusicPlayer.nowPlayingItem`
///   （MediaPlayer framework）。`NSAppleMusicUsageDescription` +
///   メディアライブラリ権限が必要。
/// - macOS: ミュージック.app を ScriptingBridge で照会（実装は #668 の macOS
///   スパイク結果次第。未対応の間は factory が macOS を本 provider に繋がない）。
///
/// ネイティブ I/O は Windows SMTC (#484) と同じ入口に揃える — メソッドチャンネル
/// `capsicum/now_playing` の `getNowPlaying` が title / artist / albumTitle の
/// マップを返し、それを [NowPlayingInfo] へ変換する。
///
/// 設計どおり Apple Music も **「文字情報のみの源」** として扱い、
/// `NowPlayingInfo.url` は常に null（`MPMediaItem` は共有 URL を持たない。URL 源は
/// Spotify provider が担う）。初回取得時にネイティブ側が権限ダイアログを出し、
/// 拒否・未再生・チャンネル未登録はいずれも null に倒す。
///
/// 実機 I/O から切り離してテストするため、変換ロジックは
/// [nowPlayingFromAppleMusicMetadata] に切り出す。
class AppleMusicNowPlayingProvider implements NowPlayingProvider {
  const AppleMusicNowPlayingProvider();

  static const _channel = MethodChannel('capsicum/now_playing');

  @override
  // iOS / macOS でのみ生成されるため、provider が存在する＝この OS で利用可能。
  // 実際に再生中の曲が取れるか・権限が下りるかは currentlyPlaying 時に判定する。
  bool get isAvailable => true;

  @override
  Future<NowPlayingInfo?> currentlyPlaying() async {
    final Map<String, Object?>? raw;
    try {
      raw = await _channel.invokeMapMethod<String, Object?>('getNowPlaying');
    } catch (_) {
      // チャンネル未登録 / ネイティブ例外は null に倒す（resolver が次の源へ）。
      return null;
    }
    if (raw == null) return null;
    // macOS は「曲なし(null)」と区別して失敗種別＋診断（AEDetermine の status /
    // スクリプト要素数）を返す（iOS は常に通常マップか null で、このマーカーは
    // 付かない）。TCC 由来は許可案内のため例外で伝播。それ以外（no_track /
    // script_error）は #668 build 111 の「即・曲なし」を切り分けるため、診断を
    // Sentry に残して「曲なし(null)」に倒す。
    final errorKind = raw['__nowPlayingError'];
    if (errorKind is String) {
      if (errorKind == 'automation_denied' ||
          errorKind == 'automation_pending') {
        throw NowPlayingPermissionException(errorKind);
      }
      // no_track（未再生・停止・未起動）は正常系なので無音で null に倒す。
      // script_error（想定外の実行時エラー）だけ観測する。#668 の sandbox 解決は
      // temporary-exception.apple-events(com.apple.Music) で済み（build 117 で動作確認）、
      // 診断用の __automationStatus / __scriptItems タグは不要になったため落とした。
      if (errorKind == 'script_error') {
        Sentry.captureMessage(
          'nowplaying: apple music script error',
          level: SentryLevel.warning,
          withScope: (scope) {
            scope.setTag('nowplaying.source', 'apple_music');
            final code = raw!['__code'];
            if (code != null) scope.setTag('nowplaying.code', '$code');
            scope.fingerprint = ['nowplaying', 'apple_music_script_error'];
          },
        );
      }
      return null;
    }
    return nowPlayingFromAppleMusicMetadata(raw);
  }
}

/// Apple Music メソッドチャンネルの戻り値マップから [NowPlayingInfo] を組む純関数。
///
/// 曲名もアーティストも無ければ null。源アプリ名はネイティブが返さなければ
/// `'Apple Music'` を既定にする（Apple Music 固定源のため）。
NowPlayingInfo? nowPlayingFromAppleMusicMetadata(Map<String, Object?> data) {
  final title = _trimmedString(data['title']);
  final artist = _trimmedString(data['artist']);
  final album = _trimmedString(data['albumTitle']);

  if (title == null && artist == null) return null;

  return NowPlayingInfo(
    sourceAppName: _trimmedString(data['sourceAppName']) ?? 'Apple Music',
    title: title,
    artist: artist,
    album: album,
    // Apple Music は文字情報源（URL 源は Spotify provider が担う）。
    url: null,
  );
}

String? _trimmedString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

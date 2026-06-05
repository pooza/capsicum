import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/services.dart';

import 'now_playing_provider.dart';

/// Windows の System Media Transport Controls (SMTC) から「現在再生中の曲」を
/// 取得する [NowPlayingProvider] 実装 (#484)。
///
/// SMTC（`GlobalSystemMediaTransportControlsSessionManager`）の読み取りは
/// pure-Dart パッケージが無いため、Windows ランナー側に C++/WinRT の
/// メソッドチャンネル（`capsicum/now_playing` の `getNowPlaying`）を実装し、
/// その戻り値（title / artist / albumTitle / sourceAppId / status のマップ）を
/// ここで [NowPlayingInfo] に変換する。
///
/// 設計どおり SMTC も MPRIS と同じく **「文字情報のみの源」** として扱い、
/// `NowPlayingInfo.url` は常に null（SMTC はトラック URL を持たない）。
///
/// このクラスは factory が Windows のときだけ生成する。実バスでの動作確認は
/// Windows 実機（ARM 仮想環境）で行うため、変換ロジックは
/// [nowPlayingFromSmtcMetadata] に切り出してユニットテストする。
class SmtcNowPlayingProvider implements NowPlayingProvider {
  const SmtcNowPlayingProvider();

  static const _channel = MethodChannel('capsicum/now_playing');

  @override
  // Windows でのみ生成されるため、provider が存在する＝この OS で利用可能。
  bool get isAvailable => true;

  @override
  Future<NowPlayingInfo?> currentlyPlaying() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'getNowPlaying',
      );
      if (raw == null) return null;
      return nowPlayingFromSmtcMetadata(raw);
    } catch (_) {
      // チャンネル未登録（非 Windows）/ ネイティブ例外は null に倒す。
      return null;
    }
  }
}

/// SMTC メソッドチャンネルの戻り値マップから [NowPlayingInfo] を組む純関数。
///
/// ネイティブ I/O から切り離してテスト可能にする入口。曲名もアーティストも
/// 無ければ null。
NowPlayingInfo? nowPlayingFromSmtcMetadata(Map<String, Object?> data) {
  final title = _trimmedString(data['title']);
  final artist = _trimmedString(data['artist']);
  final album = _trimmedString(data['albumTitle']);

  if (title == null && artist == null) return null;

  return NowPlayingInfo(
    sourceAppName: _appName(data['sourceAppId']),
    title: title,
    artist: artist,
    album: album,
    // SMTC は文字情報源（URL 源は Spotify provider が担う）。
    url: null,
  );
}

String? _trimmedString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// `SourceAppUserModelId`（"Spotify.exe" や AUMID）からの簡易表示名。
/// 末尾の `.exe` を落とす程度に留める（厳密な AUMID 解決は v1.33 では行わない）。
String _appName(Object? sourceAppId) {
  final id = _trimmedString(sourceAppId);
  if (id == null) return '';
  return id.toLowerCase().endsWith('.exe') ? id.substring(0, id.length - 4) : id;
}

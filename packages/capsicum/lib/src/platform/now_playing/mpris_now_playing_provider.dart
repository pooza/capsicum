import 'package:capsicum_core/capsicum_core.dart';
import 'package:dbus/dbus.dart';

import 'now_playing_provider.dart';

/// Linux の MPRIS（`org.mpris.MediaPlayer2.*`, D-Bus セッションバス）から
/// 「現在再生中の曲」を取得する [NowPlayingProvider] 実装 (#466)。
///
/// pure-Dart の `dbus` パッケージで叩くため FFI 不要。Spotify Linux / VLC /
/// Rhythmbox / Elisa など MPRIS 対応プレイヤーを横断して拾う。
///
/// 設計（docs/nowplaying-design.md）どおり MPRIS は **「文字情報のみの源」**
/// として扱い、`NowPlayingInfo.url` は常に null にする（`xesam:url` はローカル
/// 再生だと `file://...` になりがちで投稿向けの URL ではないため）。整形は
/// capsicum 側フォールバック整形 / モロヘイヤ整形に委ねる。
///
/// このクラスは factory が Linux のときだけ生成する。D-Bus I/O は Linux 実機
/// でのみ検証可能なため、metadata パースは [nowPlayingFromMprisMetadata] に
/// 切り出してユニットテストする。
class MprisNowPlayingProvider implements NowPlayingProvider {
  const MprisNowPlayingProvider();

  static const _mprisPrefix = 'org.mpris.MediaPlayer2.';
  static const _rootInterface = 'org.mpris.MediaPlayer2';
  static const _playerInterface = 'org.mpris.MediaPlayer2.Player';

  @override
  // Linux でのみ生成されるため、provider が存在する＝この OS で利用可能。
  // 実際に再生中の曲があるかは currentlyPlaying() の結果で判断する。
  bool get isAvailable => true;

  @override
  Future<NowPlayingInfo?> currentlyPlaying() async {
    final client = DBusClient.session();
    try {
      final names = await client.listNames();
      final players = names.where((n) => n.startsWith(_mprisPrefix));

      // 再生中（Playing）のプレイヤーを最優先。無ければ一時停止（Paused）を
      // フォールバックに使う（ユーザーが投稿のために一時停止しているケース）。
      NowPlayingInfo? paused;
      for (final name in players) {
        final result = await _readPlayer(client, name);
        if (result == null) continue;
        final (info, status) = result;
        if (status == 'Playing') return info;
        paused ??= info;
      }
      return paused;
    } catch (_) {
      // セッションバスが無い / 権限が無い等。素直に null に倒す
      // （呼び出し側＝リゾルバが次の源にフォールバックする）。
      return null;
    } finally {
      await client.close();
    }
  }

  /// 1 プレイヤーの再生状態と曲情報を読む。`(info, playbackStatus)` を返す。
  /// 読めない / Stopped / 曲情報が空なら null。
  Future<(NowPlayingInfo, String)?> _readPlayer(
    DBusClient client,
    String busName,
  ) async {
    try {
      final object = DBusRemoteObject(
        client,
        name: busName,
        path: DBusObjectPath('/org/mpris/MediaPlayer2'),
      );
      final status = (await object.getProperty(
        _playerInterface,
        'PlaybackStatus',
      )).asString();
      if (status == 'Stopped') return null;

      final metadataDict = (await object.getProperty(
        _playerInterface,
        'Metadata',
      )).asDict();
      final metadata = <String, Object?>{
        for (final entry in metadataDict.entries)
          entry.key.asString(): entry.value.asVariant().toNative(),
      };

      final identity = await _identity(object, busName);
      final info = nowPlayingFromMprisMetadata(
        metadata,
        sourceAppName: identity,
      );
      if (info == null) return null;
      return (info, status);
    } catch (_) {
      return null;
    }
  }

  /// プレイヤーの表示名（`Identity` プロパティ。"Spotify" / "VLC media player"
  /// 等）。取れなければバス名サフィックスにフォールバック。
  Future<String> _identity(DBusRemoteObject object, String busName) async {
    try {
      final id = (await object.getProperty(
        _rootInterface,
        'Identity',
      )).asString();
      if (id.trim().isNotEmpty) return id.trim();
    } catch (_) {
      // Identity 未実装のプレイヤーもある。
    }
    return busName.substring(_mprisPrefix.length);
  }
}

/// MPRIS の Metadata（`xesam:*` / `mpris:*`）から [NowPlayingInfo] を組む純関数。
///
/// D-Bus I/O から切り離してテスト可能にするための入口。[metadata] は
/// `entry.value.asVariant().toNative()` で Dart ネイティブ化した値のマップ
/// （`xesam:title` → String、`xesam:artist` → List/String、など）。
///
/// 曲名もアーティストも無ければ null（ナウプレとして意味を成さない）。
NowPlayingInfo? nowPlayingFromMprisMetadata(
  Map<String, Object?> metadata, {
  required String sourceAppName,
}) {
  final title = _trimmedString(metadata['xesam:title']);
  final artist = _joinArtists(metadata['xesam:artist']);
  final album = _trimmedString(metadata['xesam:album']);

  if ((title == null) && (artist == null)) return null;

  return NowPlayingInfo(
    sourceAppName: sourceAppName,
    title: title,
    artist: artist,
    album: album,
    // mpris:artUrl は http(s) のときだけ拾う（file:// ローカルパスは投稿に
    // 使えない）。v1.33 では添付しないが、モデルにだけ持たせておく。
    artworkUrl: _httpUri(metadata['mpris:artUrl']),
    // MPRIS は文字情報源として扱う（URL 源は Spotify provider が担う）。
    url: null,
  );
}

String? _trimmedString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// `xesam:artist` は通常 `as`（文字列配列）。非準拠プレイヤー対策で単一文字列も
/// 受ける。空要素は除き ", " で連結。
String? _joinArtists(Object? value) {
  if (value is List) {
    final names = value
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    return names.isEmpty ? null : names.join(', ');
  }
  return _trimmedString(value);
}

Uri? _httpUri(Object? value) {
  if (value is! String) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null) return null;
  return (uri.scheme == 'http' || uri.scheme == 'https') ? uri : null;
}

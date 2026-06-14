import FlutterMacOS
import Foundation

/// ミュージック.app（Apple Music）の「現在再生中の曲」を AppleScript 経由で取得し、
/// Dart 側 AppleMusicNowPlayingProvider (#668) に返すプラグイン。
///
/// チャンネル名 `capsicum/now_playing` / メソッド `getNowPlaying` は iOS / Windows
/// SMTC (#484) と揃える（OS ネイティブ pull の共通入口）。
///
/// iOS は MediaPlayer framework だが、macOS は他アプリ（ミュージック.app）への
/// 照会となるため AppleScript（Apple Events）を使う。App Sandbox 下では
/// `com.apple.security.automation.apple-events` entitlement と
/// `NSAppleEventsUsageDescription` が必要で、初回送信時に TCC「オートメーション」
/// 許可ダイアログが出る。拒否（-1743）・未再生・ミュージック未起動はいずれも
/// nil を返し、Dart 側 resolver が「再生中の曲がありません」へフォールバックする。
final class NowPlayingPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "capsicum/now_playing",
      binaryMessenger: registrar.messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getNowPlaying":
        result(currentItemMap())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// ミュージック.app の現在の曲を title / artist / albumTitle のマップにする。
  /// 未起動・停止中・曲なしは nil。`application "Music" is running` を tell の外で
  /// 判定することで、未起動のミュージックを副作用で起動しないようにする。
  private static func currentItemMap() -> [String: Any]? {
    let source = """
      if application "Music" is running then
        tell application "Music"
          try
            if player state is stopped then return {}
          end try
          set trackName to ""
          set trackArtist to ""
          set trackAlbum to ""
          try
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackAlbum to album of current track
          end try
          return {trackName, trackArtist, trackAlbum}
        end tell
      else
        return {}
      end if
      """
    var errorInfo: NSDictionary?
    guard
      let descriptor = NSAppleScript(source: source)?
        .executeAndReturnError(&errorInfo)
    else {
      // TCC 拒否 (-1743) / 構文以外の実行時エラー。nil に倒して次の源へ。
      return nil
    }
    // 空 {} は 0 要素。曲があれば {name, artist, album} の 3 要素リスト。
    guard descriptor.numberOfItems >= 3 else { return nil }
    var map: [String: Any] = [:]
    // NSAppleEventDescriptor のリストは 1 始まり。
    if let title = descriptor.atIndex(1)?.stringValue, !title.isEmpty {
      map["title"] = title
    }
    if let artist = descriptor.atIndex(2)?.stringValue, !artist.isEmpty {
      map["artist"] = artist
    }
    if let album = descriptor.atIndex(3)?.stringValue, !album.isEmpty {
      map["albumTitle"] = album
    }
    return map.isEmpty ? nil : map
  }
}

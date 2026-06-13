import Flutter
import Foundation
import MediaPlayer

/// Apple Music（ミュージック.app）の「現在再生中の曲」を MediaPlayer framework
/// 経由で取得し、Dart 側 AppleMusicNowPlayingProvider (#668) に返すプラグイン。
///
/// チャンネル名 `capsicum/now_playing` / メソッド `getNowPlaying` は Windows
/// SMTC (#484) と揃える（OS ネイティブ pull の共通入口）。
///
/// `MPMusicPlayerController.systemMusicPlayer` はミュージックアプリの再生状態を
/// 反映する **App Store 許可の公開 API**（private MediaRemote.framework は使わ
/// ない）。`nowPlayingItem` の読み取りはメディアライブラリ権限
/// （`NSAppleMusicUsageDescription`）を要するため、初回取得時に
/// `requestAuthorization` でダイアログを出す。拒否・未再生はいずれも nil を返し、
/// Dart 側 resolver が「再生中の曲がありません」へフォールバックする。
final class NowPlayingPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "capsicum/now_playing",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getNowPlaying":
        handleGetNowPlaying(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func handleGetNowPlaying(result: @escaping FlutterResult) {
    switch MPMediaLibrary.authorizationStatus() {
    case .authorized:
      result(currentItemMap())
    case .notDetermined:
      // 初回押下時にここでダイアログが出る。許可されたら読み取り、それ以外は nil。
      MPMediaLibrary.requestAuthorization { status in
        DispatchQueue.main.async {
          result(status == .authorized ? currentItemMap() : nil)
        }
      }
    case .denied, .restricted:
      result(nil)
    @unknown default:
      result(nil)
    }
  }

  /// 現在ミュージックアプリにロードされている曲を title / artist / albumTitle の
  /// マップにする。曲が無い・メタデータが空なら nil（Dart 側で「曲なし」扱い）。
  /// 再生 / 一時停止は問わない（ユーザーは「今の曲」を入れたいだけ）。
  private static func currentItemMap() -> [String: Any]? {
    guard let item = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem
    else { return nil }
    var map: [String: Any] = [:]
    if let title = item.title { map["title"] = title }
    if let artist = item.artist { map["artist"] = artist }
    if let album = item.albumTitle { map["albumTitle"] = album }
    return map.isEmpty ? nil : map
  }
}

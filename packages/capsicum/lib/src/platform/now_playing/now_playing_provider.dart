import 'package:capsicum_core/capsicum_core.dart';

/// 単一の「現在再生中の曲」取得源を表す抽象 (#466 / v1.33)。
///
/// 取得源は OS ネイティブ（Linux=MPRIS / Windows=SMTC）と Spotify
/// （mulukhiya 経由・OS 非依存）の 2 軸があり、両方ともこの interface を
/// 実装する。源の選択・優先順位づけは [NowPlayingResolver] が担い、各 provider
/// は「自分が取れるかどうか」だけに責務を絞る（design: docs/nowplaying-design.md）。
abstract class NowPlayingProvider {
  /// この端末 / アカウントでこの源が利用可能か（同期判定）。
  ///
  /// compose 画面の「ナウプレを挿入」ボタンの表示可否に使う。OS ネイティブ源
  /// は当該 OS でのみ true、Spotify 源は「アカウントが Spotify 連携済み」で
  /// のみ true になる。実 I/O を伴わない軽い判定にすること。
  bool get isAvailable;

  /// 現在再生中の曲情報を返す。取得できなければ（再生していない / 失敗）null。
  ///
  /// 例外は投げず null に倒すこと（呼び出し側はフォールバックとして次の源を
  /// 試す / 「再生中の曲がありません」を出す）。**ただし** OS の許可不足で源を
  /// そもそも照会できないケースだけは「曲なし」と区別できるよう
  /// [NowPlayingPermissionException] を投げてよい（例: macOS のミュージック.app
  /// への Apple Events が TCC「オートメーション」で拒否されている #668）。これは
  /// 「無音」ではなく「ユーザー操作で解消しうる設定不備」なので、呼び出し側が
  /// 専用の案内を出せる。
  Future<NowPlayingInfo?> currentlyPlaying();
}

/// OS の許可不足で源を照会できないことを表す例外 (#668)。
///
/// 「再生中の曲がない（null）」とは区別される、ユーザー操作（許可付与）で解消
/// しうる状態。[NowPlayingResolver] はこの例外だけは握り潰さず伝播させ、compose
/// 側が「再生中の曲がありません」ではなく許可案内を出せるようにする。
class NowPlayingPermissionException implements Exception {
  /// 失敗の機械可読な理由。macOS では `'automation_denied'`（TCC 拒否 -1743）/
  /// `'automation_pending'`（許可ダイアログ応答待ち -1744）。
  final String reason;

  const NowPlayingPermissionException(this.reason);

  @override
  String toString() => 'NowPlayingPermissionException($reason)';
}

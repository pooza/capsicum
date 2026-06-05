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
  /// 試す / 「再生中の曲がありません」を出す）。
  Future<NowPlayingInfo?> currentlyPlaying();
}

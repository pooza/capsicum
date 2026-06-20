/// タイムライン streaming のライブ接続状態 (#714)。backend の streaming 実装が
/// 接続ライフサイクルの遷移ごとに通知し、provider → UI の常時インジケータへ
/// 流す。再接続枯渇の可視化 (#588) は [exhausted] の特殊ケースとして内包する。
enum StreamConnectionState {
  /// 初回接続試行中 / 再接続中（まだ live ではない）。
  connecting,

  /// 接続済みでライブ更新を受信できる状態。
  live,

  /// 一時的に切断され、バックオフ後に再接続を試みる状態。
  disconnected,

  /// 再接続上限に到達して諦めた状態。pull-to-refresh / タブ再選択で復帰する。
  exhausted,
}

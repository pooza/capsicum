import '../../model/post.dart';
import '../../model/stream_connection_state.dart';
import '../../model/tab_type.dart';

abstract mixin class StreamSupport {
  /// Returns a stream of new posts for the given tab.
  ///
  /// ⚠ [tab] は [TimelineTab] だけでなく [HashtagTab] / [ListTab] / [ChannelTab]
  /// も取る (#1098)。デッキの主役はタグ / リスト / チャンネルのカラムなので、
  /// 「並べたのに動かない」を無くすために購読先を種別ではなくタブで受ける。
  ///
  /// ⚠⚠ **対応するチャンネルを持たないタブでは空ストリームを返す**こと。
  /// 既定のチャンネルへ黙って落とすと、そのタブが**別の TL を隠れ購読する**
  /// （Misskey の DM タブが裏で homeTimeline を購読していた #793 が実例）。
  ///
  /// [key] は購読の識別子 (#1089 / #1090)。**同じアダプタ（＝同じアカウント）で
  /// 複数の購読を同時に持てる**よう、購読はキーごとに独立している。
  ///
  /// - 同じ [key] で呼び直すと、**そのキーの**前の購読だけを閉じて張り直す
  /// - 別の [key] の購読には触らない（⚠ 以前は単数で持っており、2 本目を張ると
  ///   1 本目が**黙って止まっていた**。デッキで同じアカウントの home と local を
  ///   並べると片方しかライブにならない・`docs/deck-ui-plan.md` B-1）
  ///
  /// ⚠ 接続方式（キーごとにソケットを分けるか、1 本に多重化するか）は実装の内部
  /// 事情で、呼び出し側からは見えない（決定済み事項 2-A）。呼び出し側は TL の
  /// 文脈キー（`<アカウント>|<種別>`）をそのまま渡す想定。
  ///
  /// [onParseError] は実装内部で raw payload の JSON parse / 型変換に失敗した
  /// ときに呼ばれる任意コールバック。サーバー schema 変更を観測するため、
  /// 呼び出し側 (capsicum 本体) で Sentry 計装に繋げる用途を想定 (#586)。
  ///
  /// [onStreamError] は接続層 (TLS / DNS / WebSocket abort 等) で発生した
  /// error を観測層に流すための任意コールバック。null なら無視 (#586)。
  ///
  /// [onReconnectExhausted] は再接続上限に到達して諦めたときに 1 回だけ
  /// 呼ばれる。UI 警告や Sentry captureMessage に繋ぐ用途を想定 (#586)。
  ///
  /// [onConnectionState] は接続ライフサイクル (connecting / live / disconnected
  /// / exhausted) の遷移ごとに呼ばれる。常時の接続インジケータを出す用途を
  /// 想定 (#714)。同じ状態が連続するときは重複通知しない。
  ///
  /// [onDisconnect] は WebSocket が onDone で閉じたときに closeCode / closeReason
  /// とともに呼ばれる。本番でどんな切れ方をしているか (1000 / 1001 / 1006 …) を
  /// Sentry で観測する用途を想定 (#788)。null なら無視。
  Stream<Post> streamTimeline(
    String key,
    TabType tab, {
    void Function(Object error, StackTrace stack)? onParseError,
    void Function(Object error, StackTrace stack)? onStreamError,
    void Function()? onReconnectExhausted,
    void Function(StreamConnectionState state)? onConnectionState,
    void Function(int? closeCode, String? closeReason)? onDisconnect,
  });

  /// [key] の購読だけを閉じる。他のキーの購読には触らない。無ければ何もしない。
  ///
  /// ⚠ デッキで同じ中身のカラムが重複しているときは provider を共有するので、
  /// 呼ぶのは「最後の 1 本が消えたとき」だけ（autoDispose の `onDispose`・
  /// 決定済み事項 6-3）。カラムを 1 本削除しただけで呼ばないこと。
  void disposeStream(String key);
}

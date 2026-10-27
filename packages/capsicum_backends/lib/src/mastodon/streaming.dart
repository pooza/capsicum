import 'dart:async';
import 'dart:convert';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../reconnecting_socket.dart';
import 'extensions.dart';

/// 購読する `stream` と、必要な追加パラメータ。対応しないタブは null (#1098)。
///
/// ⚠ **Mastodon の `hashtag` ストリームはタグを 1 つしか取らない。**capsicum の
/// AND 指定（spec `"a+b"`）に当たるものが無いので、**AND のカラムは購読しない**
/// （従来どおり再取得で更新する）。⚠⚠ 代表タグだけで購読すると、**AND を
/// 満たさない投稿がカラムへ流れ込む** —— 「並べたのに動かない」より悪い。
///
/// ⚠ **チャンネルは Mastodon に存在しない。**
typedef MastodonStreamTarget = ({String stream, String? tag, String? list});

MastodonStreamTarget? mastodonStreamTarget(TabType tab) {
  switch (tab) {
    case TimelineTab(type: final type):
      final name = switch (type) {
        TimelineType.home => 'user',
        TimelineType.local => 'public:local',
        TimelineType.federated => 'public',
        TimelineType.remote => 'public:remote',
        // DM には専用ストリームが無い。'user' へ落とすと DM タブに DM でない
        // 投稿が混ざる (#793)。social も Mastodon には無い。
        _ => null,
      };
      return name == null ? null : (stream: name, tag: null, list: null);
    case HashtagTab() && final tab:
      // ⚠ 割り方の正本は capsicum_core の HashtagQuery (#1159 / #1209)。
      // Mastodon の `hashtag` ストリームはタグ 1 つしか受けないので、AND・OR・
      // 除外のある条件には張らない（それらは購読を重ねる・
      // [mastodonHashtagSubscriptions]・#1277）。
      final single = tab.query.singleTag;
      if (single == null) return null;
      return (stream: 'hashtag', tag: single, list: null);
    case ListTab(id: final id):
      return id.isEmpty ? null : (stream: 'list', tag: null, list: id);
    default:
      return null;
  }
}

/// 条件が 2 つ以上あるタグ TL で購読するタグ (#1277)。それ以外は null。
///
/// Mastodon の `hashtag` ストリームはタグ 1 つしか受けないので、**1 本の接続に
/// タグごとの購読を載せる**（接続後に `{"type":"subscribe", …}` を送る・接続の
/// 本数は増えない）。購読するのは、届く投稿が必ずそのタグを持つものだけ:
///
/// - 「いずれか」があれば、その全部（OR のどれかで届く）
/// - 「すべて含む」だけなら、その先頭 1 つ（残りは端末側で確かめる）
///
/// ⚠ 残りの条件（「すべて含む」の残り・「含まない」）は**ここでは見ない。**
/// タグ TL の provider が、ライブの投稿にも REST と同じ確かめ直し
/// （`postKeptByHashtagQuery`）を掛けている。素朴なタグの比較はサーバーの正規化
/// （全角 → 半角など）とずれるので、そちらの作法に任せる。⚠⚠ その確かめが
/// 当てにならないタグを残りに含む条件には、張らない
/// （`HashtagQuery.verifiableOnDevice`）。
List<String>? mastodonHashtagSubscriptions(TabType tab) {
  if (tab is! HashtagTab) return null;
  final query = tab.query;
  if (query.singleTag != null) return null; // 1 つなら接続の URL で張る
  // ⚠⚠ 端末側で確かめられない条件には張らない。張ると、「すべて含む」の残りや
  // 「含まない」を満たさない投稿が流れ込む（引っ張って更新で消えるが、それまで
  // 条件の外の投稿が並ぶ）。
  if (!query.verifiableOnDevice) return null;
  if (query.any.isNotEmpty) return query.any;
  if (query.all.isNotEmpty) return [query.all.first];
  return null;
}

/// [tab] にライブ更新を張れるか。
bool mastodonCanStream(TabType tab) =>
    mastodonStreamTarget(tab) != null ||
    mastodonHashtagSubscriptions(tab) != null;

class MastodonStreaming with ReconnectTuning, StreamConnectionStateReporter {
  final String host;
  final String accessToken;

  /// role ID ベースの管理者判定に使う。REST 経路 (`MastodonAdapter._adminRoleIds`)
  /// と同じ値を渡し、streaming 経由でライブ追加された投稿でも同一管理者が
  /// 一貫してマーキングされるようにする (#600)。
  final Set<String> adminRoleIds;

  /// 本線タイムライン streaming の観測コールバック (#586)。chat_streaming
  /// (#448 / #552) と同型。null なら無視。原因対処はせず計器のみ生やす。
  final void Function(Object error, StackTrace stack)? onParseError;
  final void Function(Object error, StackTrace stack)? onStreamError;
  final void Function()? onReconnectExhausted;

  /// 接続ライフサイクルの遷移を呼び出し側 (UI インジケータ) へ流す (#714)。
  @override
  final void Function(StreamConnectionState state)? onConnectionState;

  /// 切断 (onDone) 時の WebSocket closeCode / closeReason を観測層へ流す (#788)。
  /// 無音切断の検知層 (pingInterval) を入れた今、本番で「どんな切れ方をして
  /// いるか」(1000 正常 / 1001 ping タイムアウト goingAway / 1006 異常 …) を
  /// Sentry で見るための計装。現象すら未把握なので原因対処はせず計器のみ。
  /// null なら無視。
  final void Function(int? closeCode, String? closeReason)? onDisconnect;

  /// WebSocket を開く手段。null なら実際に [host] へ接続する。
  ///
  /// テストでローカルのサーバーへ向けるための差し替え口 (#1090)。接続を固定する
  /// テストはそれまで 1 本も無かった（計算とパースだけ）。
  final WebSocketChannel Function(Uri uri)? channelFactory;

  StreamController<Post>? _controller;
  ReconnectingSocket? _socket;

  /// 流した投稿の id（新しい順に [_seenIdsLimit] 件まで）。複数のタグを購読した
  /// ときの重複を落とす (#1277)。⚠ つなぎ直すたびに空にする（取りこぼしの補完は
  /// provider 側の id での重複除去が受ける）。
  final _seenIds = <String>{};
  static const _seenIdsLimit = 500;
  bool _disposed = false;

  @override
  bool get isStreamDisposed => _disposed;

  /// タイムラインは「即時」の値で再接続する (#1340)。理由は
  /// [ReconnectProfile.live]。
  @override
  ReconnectProfile get reconnectProfile => ReconnectProfile.live;

  MastodonStreaming({
    required this.host,
    required this.accessToken,
    this.adminRoleIds = const {},
    this.onParseError,
    this.onStreamError,
    this.onReconnectExhausted,
    this.onConnectionState,
    this.onDisconnect,
    this.channelFactory,
  });

  Stream<Post> connect(TabType tab) {
    // 対応する stream を持たないタブは購読しない (#793 / #1098)。既定の 'user'
    // へ落とすと、そのタブが裏でホームを購読することになる。
    if (!mastodonCanStream(tab)) return const Stream.empty();
    _controller?.close();
    _controller = StreamController<Post>.broadcast(onCancel: dispose);

    final target = mastodonStreamTarget(tab);
    final subscriptions = target == null
        ? mastodonHashtagSubscriptions(tab)
        : null;
    final uri = Uri(
      scheme: 'wss',
      host: host,
      path: '/api/v1/streaming',
      queryParameters: {
        'access_token': accessToken,
        // ⚠ 複数タグは stream を付けずに接続し、繋がってから購読を送る (#1277)。
        if (target != null) 'stream': target.stream,
        if (target?.tag != null) 'tag': target!.tag!,
        if (target?.list != null) 'list': target!.list!,
      },
    );

    // ⚠ つなぐ・切れたら予約する・数える、は [ReconnectingSocket] が持つ
    // (#1265)。握手の上限・1 回の失敗を 1 回だけ数える・安定を待ってから
    // 数え直す、は通知とチャット（#1252）と同じになる。
    _socket?.dispose();
    _socket = ReconnectingSocket.tuned(
      this,
      buildUri: () => uri,
      onMessage: _onMessage,
      subscribeMessages: () => [
        for (final tag in subscriptions ?? const <String>[])
          jsonEncode({'type': 'subscribe', 'stream': 'hashtag', 'tag': tag}),
      ],
      onStreamError: onStreamError,
      onReconnectExhausted: reportExhausted(onReconnectExhausted),
      onConnectionEvent: reportConnectionEvent,
      onConnecting: () {
        _seenIds.clear();
        notifyConnectionState(StreamConnectionState.connecting);
      },
      onClosed: onDisconnect,
      channelFactory: channelFactory,
    )..connect();
    return _controller!.stream;
  }

  void _onMessage(dynamic message) {
    if (message is! String) return;
    try {
      final json = jsonDecode(message) as Map<String, dynamic>;
      if (json['event'] != 'update') return;
      final payload = json['payload'];
      final statusJson = payload is String
          ? jsonDecode(payload) as Map<String, dynamic>
          : payload as Map<String, dynamic>;
      final status = MastodonStatus.fromJson(statusJson);
      // ⚠ 複数のタグを購読していると、両方のタグを持つ投稿が購読の数だけ届く
      // (#1277)。同じ id は 1 回だけ流す。
      if (!_seenIds.add(status.id)) return;
      if (_seenIds.length > _seenIdsLimit) _seenIds.remove(_seenIds.first);
      _controller?.add(status.toCapsicum(host, adminRoleIds: adminRoleIds));
    } catch (e, st) {
      // raw payload を捨てる前に観測層へ流す。サーバー側 schema 変更や
      // パース失敗を「ストリーミング来ない」だけで気付けなくなるのを避ける
      // (#586 / chat_streaming #448 と同型)。
      try {
        onParseError?.call(e, st);
      } catch (_) {
        // 観測経路の失敗で本筋を止めない。
      }
    }
  }

  void dispose() {
    _disposed = true;
    _socket?.dispose();
    _socket = null;
    _controller?.close();
    _controller = null;
  }
}

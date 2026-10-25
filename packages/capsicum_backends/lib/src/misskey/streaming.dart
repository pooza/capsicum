import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../reconnecting_socket.dart';
import '../streaming_backoff.dart';
import 'extensions.dart';

/// 購読するチャンネルと `params`。対応するチャンネルが無いタブは null (#1098)。
///
/// ⚠⚠ **`hashtag` / `userList` / `channel` は `params` が要る。**Misskey は
/// `params` が欠けていても**例外にせず `init` が `false` を返すだけ**なので、
/// 購読が黙って張られない（#1089 で踏んだ「黙って止まる」と同型）。
///
/// ⚠ `hashtag` の `q` は **AND の OR** を表す 2 次元配列。capsicum の spec
/// `"a+b"`（AND 指定）は `[["a","b"]]` になる。
typedef MisskeyStreamChannel = ({String channel, Map<String, dynamic>? params});

MisskeyStreamChannel? misskeyStreamChannel(TabType tab) {
  switch (tab) {
    case TimelineTab(type: final type):
      final name = switch (type) {
        TimelineType.home => 'homeTimeline',
        TimelineType.local => 'localTimeline',
        TimelineType.social => 'hybridTimeline',
        TimelineType.federated => 'globalTimeline',
        // DM 等、チャンネルを持たない種別は購読しない (#793)。
        _ => null,
      };
      return name == null ? null : (channel: name, params: null);
    case HashtagTab() && final tab:
      // ⚠ 割り方の正本は capsicum_core の HashtagQuery (#1159)。タグに含まれる
      // `+` はエスケープされているので、ここで素の split をしない。
      // `q` は REST の `query` と同じ「外側が OR・内側が AND」(#1209)。
      // ⚠ 除外は入らない（受け口が無い）。届いたあと、TL の側が落とす。
      final q = tab.query.orOfAnds;
      // タグが 1 つも無い spec で購読すると全件が流れうるので張らない。
      if (q.isEmpty) return null;
      return (channel: 'hashtag', params: {'q': q});
    case ListTab(id: final id):
      return id.isEmpty ? null : (channel: 'userList', params: {'listId': id});
    case ChannelTab(id: final id):
      return id.isEmpty
          ? null
          : (channel: 'channel', params: {'channelId': id});
    default:
      return null;
  }
}

class MisskeyStreaming {
  final String host;
  final String accessToken;
  final Set<String> adminRoleIds;

  /// 本線タイムライン streaming の観測コールバック (#586)。chat_streaming
  /// (#448 / #552) と同型。null なら無視。原因対処はせず計器のみ生やす。
  final void Function(Object error, StackTrace stack)? onParseError;
  final void Function(Object error, StackTrace stack)? onStreamError;
  final void Function()? onReconnectExhausted;

  /// 接続ライフサイクルの遷移を呼び出し側 (UI インジケータ) へ流す (#714)。
  final void Function(StreamConnectionState state)? onConnectionState;

  /// 切断 (onDone) 時の WebSocket closeCode / closeReason を観測層へ流す (#788)。
  /// 無音切断の検知層 (pingInterval) を入れた今、本番で「どんな切れ方をして
  /// いるか」(1000 正常 / 1001 ping タイムアウト goingAway / 1006 異常 …) を
  /// Sentry で見るための計装。現象すら未把握なので原因対処はせず計器のみ。
  /// null なら無視。
  final void Function(int? closeCode, String? closeReason)? onDisconnect;

  /// WebSocket を開く手段。null なら実際に [host] へ接続する。
  ///
  /// テストでローカルのサーバーへ向けるための差し替え口 (#1089)。接続・`connect`
  /// フレームを固定するテストはそれまで 1 本も無かった（計算とパースだけ）。
  final WebSocketChannel Function(Uri uri)? channelFactory;

  StreamController<Post>? _controller;
  ReconnectingSocket? _socket;
  bool _disposed = false;
  StreamConnectionState? _lastConnectionState;
  final Random _random = Random();
  // 初動は速く（瞬間 503 / 瞬断から数秒で復帰）、上限は live クライアント向けに
  // 短め。jitter は streaming_backoff 側で付与 (#784)。
  static const _baseReconnectDelay = Duration(seconds: 1);
  static const _maxReconnectDelay = Duration(seconds: 60);
  // 無音切断を検知するための WS ping/pong。pong が無ければ自動 close → onDone →
  // 再接続が走る (#788)。本線タイムラインは即時性が要るので短め。
  static const _pingInterval = Duration(seconds: 30);

  MisskeyStreaming({
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

  // 同じ状態が連続するときは UI へ重複通知しない (#714)。観測経路の失敗で
  // 本筋を止めない。
  void _notifyConnectionState(StreamConnectionState next) {
    if (_disposed || _lastConnectionState == next) return;
    _lastConnectionState = next;
    try {
      onConnectionState?.call(next);
    } catch (_) {}
  }

  Stream<Post> connect(TabType tab) {
    // チャンネルを持たないタブ (DM 等) は購読しない。以前は購読時に
    // `_channelMap[type] ?? 'homeTimeline'` で homeTimeline に化け、DM タブが
    // 裏でホームを隠れ購読していた (#793)。Mastodon 側 (streamTimeline が DM で
    // Stream.empty を返す) と挙動を揃える。
    final target = misskeyStreamChannel(tab);
    if (target == null) return const Stream.empty();
    _controller?.close();
    _controller = StreamController<Post>.broadcast(onCancel: dispose);

    // ⚠ つなぐ・切れたら予約する・数える、は [ReconnectingSocket] が持つ
    // (#1265)。握手の上限・1 回の失敗を 1 回だけ数える・安定を待ってから
    // 数え直す、は通知とチャット（#1252）と同じになる。
    _socket?.dispose();
    _socket = ReconnectingSocket(
      buildUri: () => Uri(
        scheme: 'wss',
        host: host,
        path: '/streaming',
        queryParameters: {'i': accessToken},
      ),
      onMessage: _onMessage,
      // 購読の id は接続ごとに作り直す。
      subscribeMessages: () => [
        jsonEncode({
          'type': 'connect',
          'body': {
            'channel': target.channel,
            'id': const Uuid().v4(),
            // ⚠ hashtag / userList / channel は params 必須。欠けると
            // init が false を返すだけで、例外なしに購読が張られない。
            if (target.params != null) 'params': target.params,
          },
        }),
      ],
      delayFor: reconnectDelayFor,
      onStreamError: onStreamError,
      onReconnectExhausted: () {
        try {
          onReconnectExhausted?.call();
        } catch (_) {
          // 観測経路の失敗で本筋を止めない。
        }
        _notifyConnectionState(StreamConnectionState.exhausted);
      },
      onConnectionEvent: (event) {
        if (event == ReconnectingSocket.connected) {
          _notifyConnectionState(StreamConnectionState.live);
        } else if (event == ReconnectingSocket.disconnected) {
          _notifyConnectionState(StreamConnectionState.disconnected);
        }
      },
      onConnecting: () =>
          _notifyConnectionState(StreamConnectionState.connecting),
      onClosed: onDisconnect,
      channelFactory: channelFactory,
      pingInterval: _pingInterval,
      connectTimeout: connectTimeout,
      stableAfter: stableConnectionAfter,
    )..connect();
    return _controller!.stream;
  }

  /// 握手を待つ上限 (#1265)。⚠ テストが縮める。
  Duration get connectTimeout => const Duration(seconds: 30);

  /// これだけつながり続けたら、失敗を数え直す (#1265)。⚠ テストが縮める。
  Duration get stableConnectionAfter => const Duration(seconds: 30);

  /// [attempt] 回目（0 始まり）の再接続までの待ち時間。⚠ テストが上書きする。
  Duration reconnectDelayFor(int attempt) => Duration(
    milliseconds: reconnectBackoffMs(
      attempt,
      baseMs: _baseReconnectDelay.inMilliseconds,
      maxMs: _maxReconnectDelay.inMilliseconds,
      random: _random,
    ),
  );

  void _onMessage(dynamic message) {
    if (message is! String) return;
    try {
      final json = jsonDecode(message) as Map<String, dynamic>;
      if (json['type'] != 'channel') return;
      final body = json['body'] as Map<String, dynamic>;
      if (body['type'] != 'note') return;
      final noteJson = body['body'] as Map<String, dynamic>;
      final note = MisskeyNote.fromJson(noteJson);
      _controller?.add(note.toCapsicum(host, adminRoleIds: adminRoleIds));
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

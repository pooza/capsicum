import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../streaming_backoff.dart';
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
        // DM には専用ストリームが無い。'user' へ落とすと DM タブに DM でない
        // 投稿が混ざる (#793)。social も Mastodon には無い。
        _ => null,
      };
      return name == null ? null : (stream: name, tag: null, list: null);
    case HashtagTab(tag: final spec):
      final tags = spec.split('+').where((t) => t.isNotEmpty).toList();
      // AND 指定は Mastodon の streaming で表現できないので張らない。
      if (tags.length != 1) return null;
      return (stream: 'hashtag', tag: tags.first, list: null);
    case ListTab(id: final id):
      return id.isEmpty ? null : (stream: 'list', tag: null, list: id);
    default:
      return null;
  }
}

class MastodonStreaming {
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

  WebSocketChannel? _channel;
  StreamController<Post>? _controller;
  Timer? _reconnectTimer;
  TabType? _currentTab;
  bool _disposed = false;
  bool _reconnectExhaustedNotified = false;
  StreamConnectionState? _lastConnectionState;
  int _reconnectAttempts = 0;
  final Random _random = Random();
  // 上限 = exhausted を一度だけ通知する閾値（give-up はしない, #784）。
  static const _maxReconnectAttempts = 10;
  // 初動は速く（瞬間 503 / 瞬断から数秒で復帰）、上限は live クライアント向けに
  // 短め（5 分待ちは実況で長すぎる）。jitter は streaming_backoff 側で付与 (#784)。
  static const _baseReconnectDelay = Duration(seconds: 1);
  static const _maxReconnectDelay = Duration(seconds: 60);
  // 無音切断（NAT/プロキシのアイドル切断・ungraceful な離脱）では FIN/RST が
  // 来ず onDone/onError が発火しないため、ping/pong を張らないと「繋がっている
  // つもり」で死んだソケットに座り続け再接続が走らない (#788)。pingInterval を
  // 設定すると dart:io が ping を送り、同間隔内に pong が無ければ自動で close →
  // onDone 発火 → 既存の再接続ロジックが動く。検知時間 ≒ pingInterval。本線
  // タイムラインは即時性が要るので短め。
  static const _pingInterval = Duration(seconds: 30);

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
    // 対応する stream を持たないタブは購読しない (#793 / #1098)。既定の 'user'
    // へ落とすと、そのタブが裏でホームを購読することになる。
    if (mastodonStreamTarget(tab) == null) return const Stream.empty();
    _currentTab = tab;
    _controller?.close();
    _controller = StreamController<Post>.broadcast(onCancel: dispose);
    _connect(tab);
    return _controller!.stream;
  }

  void _connect(TabType tab) {
    if (_disposed) return;
    _channel?.sink.close();
    _notifyConnectionState(StreamConnectionState.connecting);

    // connect() で対応しないタブは弾いてある。
    final target = mastodonStreamTarget(tab);
    if (target == null) return;
    final uri = Uri(
      scheme: 'wss',
      host: host,
      path: '/api/v1/streaming',
      queryParameters: {
        'access_token': accessToken,
        'stream': target.stream,
        if (target.tag != null) 'tag': target.tag!,
        if (target.list != null) 'list': target.list!,
      },
    );

    final factory = channelFactory;
    _channel = factory != null
        ? factory(uri)
        : IOWebSocketChannel.connect(uri, pingInterval: _pingInterval);
    _channel!.ready
        .then((_) {
          _reconnectAttempts = 0;
          _reconnectExhaustedNotified = false;
          _notifyConnectionState(StreamConnectionState.live);
        })
        .catchError((Object error, StackTrace stack) {
          _notifyStreamError(error, stack);
          _notifyConnectionState(StreamConnectionState.disconnected);
          _scheduleReconnect();
        });
    _channel!.stream.listen(
      _onMessage,
      onError: (Object error, StackTrace stack) {
        _notifyStreamError(error, stack);
        _notifyConnectionState(StreamConnectionState.disconnected);
        _scheduleReconnect();
      },
      onDone: () {
        // onDone でバックオフをリセットしてしまうと「接続→onDone→reset→
        // 再接続→onDone→reset」のループでバックオフが基底値のまま動かず、
        // 上限到達による `onReconnectExhausted` 通知も出なくなる。リセット
        // は `ready.then` の接続成功時のみ行い、DM (`chat_streaming.dart`) /
        // ルーム (`chat_room_streaming.dart`) と挙動を揃える。
        _notifyDisconnect();
        _notifyConnectionState(StreamConnectionState.disconnected);
        _scheduleReconnect();
      },
    );
  }

  void _notifyStreamError(Object error, StackTrace stack) {
    try {
      onStreamError?.call(error, stack);
    } catch (_) {
      // 観測経路の失敗で本筋を止めない。
    }
  }

  // onDone 時の closeCode/closeReason を観測層へ。閉じた直後なので channel に
  // closeCode が乗っている。観測経路の失敗で本筋を止めない (#788)。
  void _notifyDisconnect() {
    try {
      onDisconnect?.call(_channel?.closeCode, _channel?.closeReason);
    } catch (_) {}
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

  void _scheduleReconnect() {
    if (_disposed) return;
    // 上限到達時、exhausted を一度だけ通知して呼び出し側 (UI / 観測) に知らせる
    // (#586 / #552)。ただし **give-up はせず** 低頻度で再試行を続ける (#784)：
    // 間欠的に失敗するサーバー (例: 高負荷時に一瞬 503 を返す箱) / 瞬断回線でも
    // live 復帰の機会を捨てない。復帰すれば since_id catch-up (#781) が穴を埋める。
    if (_reconnectAttempts >= _maxReconnectAttempts &&
        !_reconnectExhaustedNotified) {
      _reconnectExhaustedNotified = true;
      try {
        onReconnectExhausted?.call();
      } catch (_) {
        // 観測経路の失敗で本筋を止めない。
      }
      _notifyConnectionState(StreamConnectionState.exhausted);
    }
    _reconnectTimer?.cancel();
    final delayMs = reconnectBackoffMs(
      _reconnectAttempts,
      baseMs: _baseReconnectDelay.inMilliseconds,
      maxMs: _maxReconnectDelay.inMilliseconds,
      random: _random,
    );
    _reconnectAttempts++;
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!_disposed && _currentTab != null) {
        _connect(_currentTab!);
      }
    });
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _controller?.close();
    _controller = null;
  }
}

import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../service/sentry_op_failure.dart';
import '../util/exception_scrub.dart';
import 'account_manager_provider.dart';
import 'timeline_provider.dart';

/// chat (DM) streaming の再接続上限到達フラグ (#623)。timeline 側の
/// [TimelineState.streamReconnectExhausted] と同型で、UI 画面で `ref.listen`
/// して SnackBar で可視化する。stream provider が autoDispose されるタイミ
/// ングで自動的に false に戻る (画面遷移 / アカウント切替 / pull-to-refresh
/// による再購読のいずれでもクリア)。
final chatStreamReconnectExhaustedProvider = StateProvider.autoDispose<bool>(
  (ref) => false,
);

/// 特定 roomId の chatRoom streaming の再接続上限到達フラグ (#623)。
final chatRoomStreamReconnectExhaustedProvider = StateProvider.autoDispose
    .family<bool, String>((ref, _) => false);

/// chat ストリーミング (newChatMessage) の broadcast ストリーム。
/// ChatSupport を持つ adapter のみ実体を返し、null だと購読側はスキップ。
/// onCancel で adapter 側の WebSocket を切る。
final chatMessageStreamProvider = Provider.autoDispose<Stream<ChatMessage>?>((
  ref,
) {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter is! ChatSupport) return null;
  if (!(adapter as ChatSupport).canReadChat) return null;
  // streaming 内部 parse 失敗 (server schema 変更等) を観測層に流す (#448)。
  // breadcrumb は毎回、captureException は throttle して spam を防ぐ。
  DateTime? lastParseCapture;
  DateTime? lastConnectCapture;
  const captureThrottle = Duration(seconds: 60);
  final stream = (adapter as ChatSupport).streamChatMessages(
    onParseError: (e, st) {
      Sentry.addBreadcrumb(
        Breadcrumb(
          category: 'chat.stream.parse',
          level: SentryLevel.warning,
          message: e.toString().length > 200
              ? '${e.toString().substring(0, 200)}…'
              : e.toString(),
        ),
      );
      final now = DateTime.now();
      if (lastParseCapture != null &&
          now.difference(lastParseCapture!) < captureThrottle) {
        return;
      }
      lastParseCapture = now;
      Sentry.captureException(
        scrubException(e),
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('chat.stream.parse', 'failed');
          scope.fingerprint = ['chat.stream.parse', e.runtimeType.toString()];
        },
      );
    },
    // 接続層 (TLS / DNS / WebSocket abort 等) の error を観測 (#552)。
    // 切断中は同種 error が連発しがちなので breadcrumb は毎回・
    // captureException のみ throttle する。
    onStreamError: (e, st) {
      Sentry.addBreadcrumb(
        Breadcrumb(
          category: 'chat.stream.connect',
          level: SentryLevel.warning,
          message: e.runtimeType.toString(),
        ),
      );
      final now = DateTime.now();
      if (lastConnectCapture != null &&
          now.difference(lastConnectCapture!) < captureThrottle) {
        return;
      }
      lastConnectCapture = now;
      Sentry.captureException(
        scrubException(e),
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('chat.stream.connect', 'failed');
          scope.fingerprint = ['chat.stream.connect', e.runtimeType.toString()];
        },
      );
    },
    // 再接続上限 (10 回) に到達した時点で 1 回だけ通知される。Sentry に
    // 残しつつ、UI 側で SnackBar 表示するためのフラグも立てる (#623)。
    onReconnectExhausted: () {
      Sentry.captureMessage(
        'chat.stream.reconnect_exhausted',
        level: SentryLevel.warning,
        withScope: (scope) {
          scope.setTag('chat.stream', 'reconnect_exhausted');
          scope.fingerprint = ['chat.stream.reconnect_exhausted'];
        },
      );
      ref.read(chatStreamReconnectExhaustedProvider.notifier).state = true;
    },
  );
  ref.onDispose(() => (adapter as ChatSupport).disposeChatStream());
  return stream;
});

/// /chat/history で取得するスレッド一覧。ChatSupport を持たない adapter では
/// 空リストを返す。streaming で来た新着 chat は thread を先頭に並べ替える。
class ChatThreadListNotifier
    extends AutoDisposeAsyncNotifier<List<ChatThread>> {
  StreamSubscription<ChatMessage>? _streamSub;

  @override
  Future<List<ChatThread>> build() async {
    ref.onDispose(() => _streamSub?.cancel());
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter is! ChatSupport) return const [];
    final chat = adapter as ChatSupport;

    final stream = ref.watch(chatMessageStreamProvider);
    if (stream != null) {
      _streamSub?.cancel();
      _streamSub = stream.listen(_handleStreamMessage);
    }

    // DM (chat/history?room=false) とルーム (chat/history?room=true) を同一
    // 履歴画面に出すため両方取得してマージし、lastMessage.createdAt の降順で
    // 並べる。Misskey 側 WebUI も同じ振る舞い (#438)。room 非対応の adapter
    // (Mastodon 等) は getRoomHistory のデフォルト実装が UnsupportedError を
    // 投げるので空配列にフォールバック。
    final dmThreads = await chat.getChatHistory(
      query: const TimelineQuery(limit: 100),
    );
    List<ChatThread> roomThreads = const [];
    try {
      roomThreads = await chat.getRoomHistory(
        query: const TimelineQuery(limit: 100),
      );
    } on UnsupportedError {
      // chat はあるが rooms 非対応の adapter (DM only) は静かに DM のみで継続。
    }
    final merged = [...dmThreads, ...roomThreads]
      ..sort(
        (a, b) => b.lastMessage.createdAt.compareTo(a.lastMessage.createdAt),
      );
    return merged;
  }

  void _handleStreamMessage(ChatMessage message) {
    final myUserId = ref.read(currentAccountProvider)?.user.id;
    if (myUserId == null) return;
    // 現状の chatMessageStreamProvider は main channel 由来の DM のみを emit する。
    // ルーム宛は chatRoom channel 別購読で別経路 (#438) のため、念のため弾く。
    if (message.isRoomMessage) return;
    final toUser = message.toUser;
    if (toUser == null) return;
    final isIncoming = message.fromUser.id != myUserId;
    final otherUser = isIncoming ? message.fromUser : toUser;
    final current = state.valueOrNull ?? const <ChatThread>[];
    final updated = ChatThread(
      otherUser: otherUser,
      lastMessage: message,
      isUnread: isIncoming && !message.isRead,
    );
    final filtered = current
        .where((t) => t.otherUser?.id != otherUser.id)
        .toList();
    state = AsyncData([updated, ...filtered]);
  }

  /// chatRoom channel 経由で受信した room message を thread list に反映する
  /// (#632)。閉じているルームのメッセージは元々届かないが、開いているルームで
  /// 他メンバーが発言した際に thread list が並び替わらない / 未読が更新され
  /// ない問題を解消する。room 入室画面 (ChatRoomTimelineNotifier) から呼び
  /// 出される。
  void applyRoomMessage(ChatMessage message) {
    if (!message.isRoomMessage) return;
    final myUserId = ref.read(currentAccountProvider)?.user.id;
    if (myUserId == null) return;
    final roomId = message.toRoom?.id ?? message.toRoomId;
    if (roomId == null) return;
    final current = state.valueOrNull ?? const <ChatThread>[];
    ChatThread? existing;
    for (final t in current) {
      if (t.room?.id == roomId) {
        existing = t;
        break;
      }
    }
    // 未掲載のルーム = 自分が所属しているが getRoomHistory の結果に含まれない
    // (空ルーム新規参加直後など)。履歴側を refresh するのが筋だが、ホット
    // フィックスでは既知 thread のみ更新するに留める。
    if (existing == null) return;
    final isIncoming = message.fromUser.id != myUserId;
    final updated = ChatThread(
      room: existing.room,
      lastMessage: message,
      // DM 経路と同じ式に揃える (#632 review)。room は chat_room_streaming
      // 側で `defaultIsRead: true` を強制しているため通常は read 扱いだが、
      // 将来サーバーが unread を返すよう変わっても整合する。
      isUnread: isIncoming && !message.isRead,
    );
    final filtered = current.where((t) => t.room?.id != roomId).toList();
    state = AsyncData([updated, ...filtered]);
  }
}

/// 特定ルーム (roomId) の chatRoom channel 由来の新着メッセージ broadcast
/// ストリーム。ChatSupport を持ち、かつ accessToken が引ける adapter のみ
/// 実体を返し、null だと購読側はスキップ。onCancel で adapter 側の WebSocket
/// を切る。DM 用 [chatMessageStreamProvider] と同じ観測設計 (#438)。
final chatRoomMessageStreamProvider = Provider.autoDispose
    .family<Stream<ChatMessage>?, String>((ref, roomId) {
      final adapter = ref.watch(currentAdapterProvider);
      if (adapter is! ChatSupport) return null;
      if (!(adapter as ChatSupport).canReadChat) return null;
      DateTime? lastParseCapture;
      DateTime? lastConnectCapture;
      const captureThrottle = Duration(seconds: 60);
      final stream = (adapter as ChatSupport).streamRoomMessages(
        roomId: roomId,
        onParseError: (e, st) {
          Sentry.addBreadcrumb(
            Breadcrumb(
              category: 'chat.room.stream.parse',
              level: SentryLevel.warning,
              message: e.toString().length > 200
                  ? '${e.toString().substring(0, 200)}…'
                  : e.toString(),
            ),
          );
          final now = DateTime.now();
          if (lastParseCapture != null &&
              now.difference(lastParseCapture!) < captureThrottle) {
            return;
          }
          lastParseCapture = now;
          Sentry.captureException(
            scrubException(e),
            stackTrace: st,
            withScope: (scope) {
              scope.setTag('chat.room.stream.parse', 'failed');
              scope.fingerprint = [
                'chat.room.stream.parse',
                e.runtimeType.toString(),
              ];
            },
          );
        },
        onStreamError: (e, st) {
          Sentry.addBreadcrumb(
            Breadcrumb(
              category: 'chat.room.stream.connect',
              level: SentryLevel.warning,
              message: e.runtimeType.toString(),
            ),
          );
          final now = DateTime.now();
          if (lastConnectCapture != null &&
              now.difference(lastConnectCapture!) < captureThrottle) {
            return;
          }
          lastConnectCapture = now;
          Sentry.captureException(
            scrubException(e),
            stackTrace: st,
            withScope: (scope) {
              scope.setTag('chat.room.stream.connect', 'failed');
              scope.fingerprint = [
                'chat.room.stream.connect',
                e.runtimeType.toString(),
              ];
            },
          );
        },
        onReconnectExhausted: () {
          Sentry.captureMessage(
            'chat.room.stream.reconnect_exhausted',
            level: SentryLevel.warning,
            withScope: (scope) {
              scope.setTag('chat.room.stream', 'reconnect_exhausted');
              scope.fingerprint = ['chat.room.stream.reconnect_exhausted'];
            },
          );
          ref
                  .read(
                    chatRoomStreamReconnectExhaustedProvider(roomId).notifier,
                  )
                  .state =
              true;
        },
      );
      ref.onDispose(
        () => (adapter as ChatSupport).disposeRoomChatStream(roomId: roomId),
      );
      return stream;
    });

/// 自分が参加しているルーム一覧。ChatSupport / room 非対応 adapter は空配列。
final joiningChatRoomsProvider = FutureProvider.autoDispose<List<ChatRoom>>((
  ref,
) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter is! ChatSupport) return const [];
  try {
    return await (adapter as ChatSupport).getJoiningRooms(
      query: const TimelineQuery(limit: 100),
    );
  } on UnsupportedError {
    return const [];
  }
});

/// 特定ルームのメンバー一覧 (`family<roomId>`)。
final chatRoomMembersProvider = FutureProvider.autoDispose
    .family<List<ChatRoomMember>, String>((ref, roomId) async {
      final adapter = ref.watch(currentAdapterProvider);
      if (adapter is! ChatSupport) return const [];
      try {
        return await (adapter as ChatSupport).getRoomMembers(
          roomId: roomId,
          query: const TimelineQuery(limit: 100),
        );
      } on UnsupportedError {
        return const [];
      }
    });

/// 受信招待箱。invitations/inbox 相当。
final chatInvitationInboxProvider =
    FutureProvider.autoDispose<List<ChatRoomInvitation>>((ref) async {
      final adapter = ref.watch(currentAdapterProvider);
      if (adapter is! ChatSupport) return const [];
      try {
        return await (adapter as ChatSupport).getInvitationInbox(
          query: const TimelineQuery(limit: 100),
        );
      } on UnsupportedError {
        return const [];
      }
    });

/// 特定ルームのメッセージタイムライン。DM 用 [ChatThreadNotifier] の room 版。
/// state は [ChatThreadState] を流用し、`messages` 配列は「先頭が最新、末尾が古い」
/// 順序で保持する (room-timeline も降順返却)。
class ChatRoomTimelineNotifier
    extends AutoDisposeFamilyAsyncNotifier<ChatThreadState, String> {
  static const _pageSize = 30;
  StreamSubscription<ChatMessage>? _streamSub;

  @override
  Future<ChatThreadState> build(String arg) async {
    ref.onDispose(() => _streamSub?.cancel());
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter is! ChatSupport) {
      return const ChatThreadState(hasMore: false);
    }
    final chat = adapter as ChatSupport;

    final stream = ref.watch(chatRoomMessageStreamProvider(arg));
    if (stream != null) {
      _streamSub?.cancel();
      _streamSub = stream.listen((m) => _handleStreamMessage(m, arg));
    }

    final List<ChatMessage> messages;
    try {
      messages = await chat.getRoomMessages(
        roomId: arg,
        query: const TimelineQuery(limit: _pageSize),
      );
    } on UnsupportedError {
      return const ChatThreadState(hasMore: false);
    }
    return ChatThreadState(
      messages: messages,
      hasMore: messages.length >= _pageSize,
    );
  }

  void _handleStreamMessage(ChatMessage message, String roomId) {
    // 別ルーム宛 or DM は無視。ルーム streaming は roomId を絞って購読している
    // ので普通は他ルームが来ないが、サーバー側 race / 取り違え保険。
    if (!message.isRoomMessage) return;
    if (message.toRoomId != null && message.toRoomId != roomId) return;
    // thread list (chat 履歴) にも反映して並び替え / 未読更新を起こす (#632)。
    // ChatThreadListNotifier 単独では chatRoom channel を購読しないため、
    // 開いている room 側から都度流す経路。
    //
    // ただし chatThreadListProvider は autoDispose で、thread list を誰も
    // watch していない (room を開いて即 pop した直後など) と既に dispose
    // 済み。その状態で `ref.read(...notifier)` すると provider が build() で
    // resurrect し、getChatHistory + getRoomHistory のネットワーク 2 本を
    // 意図せず叩いてしまう (#636)。生きているときだけ反映する。閉じている
    // 間の並び替え / 未読は、次に thread list を開いた際の build() が最新を
    // 取り直すので取りこぼさない。
    if (ref.exists(chatThreadListProvider)) {
      ref.read(chatThreadListProvider.notifier).applyRoomMessage(message);
    }
    final current = state.valueOrNull;
    if (current == null) return;
    if (current.messages.any((m) => m.id == message.id)) return;
    state = AsyncData(
      current.copyWith(messages: [message, ...current.messages]),
    );
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;
    if (current.messages.isEmpty) return;
    if (current.loadMoreError != null) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));

    for (var attempt = 0; attempt <= loadMoreMaxRetries; attempt++) {
      try {
        final adapter = ref.read(currentAdapterProvider);
        if (adapter is! ChatSupport) {
          state = AsyncData(current.copyWith(isLoadingMore: false));
          return;
        }
        final base = state.valueOrNull ?? current;
        final lastId = base.messages.last.id;
        final older = await (adapter as ChatSupport).getRoomMessages(
          roomId: arg,
          query: TimelineQuery(maxId: lastId, limit: _pageSize),
        );
        state = AsyncData(
          base.copyWith(
            messages: [...base.messages, ...older],
            isLoadingMore: false,
            hasMore: older.length >= _pageSize,
            loadMoreError: null,
          ),
        );
        return;
      } catch (e, st) {
        if (attempt < loadMoreMaxRetries) {
          await Future<void>.delayed(loadMoreRetryDelay);
          continue;
        }
        reportOpFailure(
          tagKey: 'chat.room.load_more',
          operation: 'failed',
          error: e,
          stackTrace: st,
          account: ref.read(currentAccountProvider),
        );
        state = AsyncData(
          (state.valueOrNull ?? current).copyWith(
            isLoadingMore: false,
            loadMoreError: e,
          ),
        );
      }
    }
  }

  Future<ChatMessage> send(String text, {String? fileId}) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! ChatSupport) {
      throw StateError('Adapter does not support chat');
    }
    final message = await (adapter as ChatSupport).sendRoomMessage(
      roomId: arg,
      text: text.isEmpty ? null : text,
      fileId: fileId,
    );
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(
        current.copyWith(messages: [message, ...current.messages]),
      );
    }
    ref.invalidate(chatThreadListProvider);
    return message;
  }

  Future<void> deleteMessage(String messageId) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! ChatSupport) return;
    await (adapter as ChatSupport).deleteChatMessage(messageId);
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(
        current.copyWith(
          messages: current.messages.where((m) => m.id != messageId).toList(),
        ),
      );
    }
    ref.invalidate(chatThreadListProvider);
  }

  /// メッセージの reaction をトグルする (#612)。自分が既に同じ reaction を
  /// 付けていれば unreact、なければ react。API 成功後に state を更新する。
  Future<void> toggleReaction(String messageId, String reaction) =>
      _toggleChatReaction(
        ref,
        () => state,
        (v) => state = v,
        messageId,
        reaction,
      );
}

/// DM・ルーム共通の reaction トグル実装 (#612)。両 Notifier は同じ
/// [ChatThreadState] を持つため処理を共有する。
Future<void> _toggleChatReaction(
  Ref ref,
  AsyncValue<ChatThreadState> Function() read,
  void Function(AsyncValue<ChatThreadState>) write,
  String messageId,
  String reaction,
) async {
  final adapter = ref.read(currentAdapterProvider);
  if (adapter is! ChatSupport) return;
  final chat = adapter as ChatSupport;
  final self = ref.read(currentAccountProvider)?.user;
  if (self == null) return;

  final current = read().valueOrNull;
  if (current == null) return;
  final idx = current.messages.indexWhere((m) => m.id == messageId);
  if (idx < 0) return;
  final message = current.messages[idx];
  final alreadyMine = message.reactions.any(
    (r) => r.reaction == reaction && r.user.id == self.id,
  );

  if (alreadyMine) {
    await chat.unreactToChatMessage(messageId: messageId, reaction: reaction);
  } else {
    await chat.reactToChatMessage(messageId: messageId, reaction: reaction);
  }

  // await 中に state が差し替わりうるので読み直してから更新する。
  final latest = read().valueOrNull;
  if (latest == null) return;
  final updated = latest.messages.map((m) {
    if (m.id != messageId) return m;
    final reactions = alreadyMine
        ? m.reactions
              .where((r) => !(r.reaction == reaction && r.user.id == self.id))
              .toList()
        : [...m.reactions, ChatReaction(reaction: reaction, user: self)];
    return m.copyWith(reactions: reactions);
  }).toList();
  write(AsyncData(latest.copyWith(messages: updated)));
}

final chatRoomTimelineProvider = AsyncNotifierProvider.autoDispose
    .family<ChatRoomTimelineNotifier, ChatThreadState, String>(
      ChatRoomTimelineNotifier.new,
    );

final chatThreadListProvider =
    AsyncNotifierProvider.autoDispose<ChatThreadListNotifier, List<ChatThread>>(
      ChatThreadListNotifier.new,
    );

/// `null` 自体が「明示的にクリア」を意味する nullable フィールドを
/// `copyWith` で保持／差し替えするための sentinel (#442 / #450 と同型)。
const Object _keepLoadMoreError = Object();

class ChatThreadState {
  final List<ChatMessage> messages;
  final bool hasMore;
  final bool isLoadingMore;

  /// 直近の [ChatThreadNotifier.loadMore] が最終的に失敗した場合の例外。
  /// スクロール由来の自動再試行を抑止する番兵として使うため、pull-to-refresh
  /// 等で build() が再実行されるまでクリアされない (#442)。
  final Object? loadMoreError;

  const ChatThreadState({
    this.messages = const [],
    this.hasMore = true,
    this.isLoadingMore = false,
    this.loadMoreError,
  });

  /// [loadMoreError] は引数省略時に現状を保持する。明示的に `null` を渡した
  /// 場合はクリア、例外を渡した場合は差し替え。
  ChatThreadState copyWith({
    List<ChatMessage>? messages,
    bool? hasMore,
    bool? isLoadingMore,
    Object? loadMoreError = _keepLoadMoreError,
  }) => ChatThreadState(
    messages: messages ?? this.messages,
    hasMore: hasMore ?? this.hasMore,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    loadMoreError: identical(loadMoreError, _keepLoadMoreError)
        ? this.loadMoreError
        : loadMoreError,
  );
}

/// 特定ユーザーとの DM メッセージ一覧。
/// Misskey の /chat/messages/user-timeline は最新→過去の順で返るため、
/// state.messages も「先頭が最新、末尾が古い」順序で保持する。
class ChatThreadNotifier
    extends AutoDisposeFamilyAsyncNotifier<ChatThreadState, String> {
  static const _pageSize = 30;
  StreamSubscription<ChatMessage>? _streamSub;

  @override
  Future<ChatThreadState> build(String arg) async {
    ref.onDispose(() => _streamSub?.cancel());
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter is! ChatSupport) {
      return const ChatThreadState(hasMore: false);
    }

    final stream = ref.watch(chatMessageStreamProvider);
    if (stream != null) {
      _streamSub?.cancel();
      _streamSub = stream.listen((m) => _handleStreamMessage(m, arg));
    }

    final messages = await (adapter as ChatSupport).getUserMessages(
      userId: arg,
      query: const TimelineQuery(limit: _pageSize),
    );
    return ChatThreadState(
      messages: messages,
      hasMore: messages.length >= _pageSize,
    );
  }

  void _handleStreamMessage(ChatMessage message, String userId) {
    // このスレッド (= userId DM) と関係ないメッセージは無視。ルーム宛
    // (toUser == null) は別 provider で扱うので常にスキップ。
    if (message.isRoomMessage) return;
    final relevant =
        message.fromUser.id == userId || message.toUser?.id == userId;
    if (!relevant) return;
    final current = state.valueOrNull;
    if (current == null) return;
    // 重複防止 (送信時の optimistic update と被るケース対策)。
    if (current.messages.any((m) => m.id == message.id)) return;
    state = AsyncData(
      current.copyWith(messages: [message, ...current.messages]),
    );
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;
    if (current.messages.isEmpty) return;
    // 直前に最終失敗で loadMoreError が立っているなら、build() 再実行
    // (pull-to-refresh 等) までスクロール再試行を止める。#442 / drive と同型。
    if (current.loadMoreError != null) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));

    for (var attempt = 0; attempt <= loadMoreMaxRetries; attempt++) {
      try {
        final adapter = ref.read(currentAdapterProvider);
        if (adapter is! ChatSupport) {
          state = AsyncData(current.copyWith(isLoadingMore: false));
          return;
        }
        final base = state.valueOrNull ?? current;
        final lastId = base.messages.last.id;
        final older = await (adapter as ChatSupport).getUserMessages(
          userId: arg,
          query: TimelineQuery(maxId: lastId, limit: _pageSize),
        );
        state = AsyncData(
          base.copyWith(
            messages: [...base.messages, ...older],
            isLoadingMore: false,
            hasMore: older.length >= _pageSize,
            loadMoreError: null,
          ),
        );
        return;
      } catch (e, st) {
        if (attempt < loadMoreMaxRetries) {
          await Future<void>.delayed(loadMoreRetryDelay);
          continue;
        }
        // 最終失敗: Sentry へ計装し、loadMoreError 番兵で次回スクロール再入
        // を止める。drive_provider と同じ形 (#442 / #430 と同型)。
        reportOpFailure(
          tagKey: 'chat.load_more',
          operation: 'failed',
          error: e,
          stackTrace: st,
          account: ref.read(currentAccountProvider),
        );
        state = AsyncData(
          (state.valueOrNull ?? current).copyWith(
            isLoadingMore: false,
            loadMoreError: e,
          ),
        );
      }
    }
  }

  Future<ChatMessage> send(String text, {String? fileId}) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! ChatSupport) {
      throw StateError('Adapter does not support chat');
    }
    final message = await (adapter as ChatSupport).sendUserMessage(
      userId: arg,
      text: text.isEmpty ? null : text,
      fileId: fileId,
    );
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(
        current.copyWith(messages: [message, ...current.messages]),
      );
    }
    ref.invalidate(chatThreadListProvider);
    return message;
  }

  Future<void> deleteMessage(String messageId) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! ChatSupport) return;
    await (adapter as ChatSupport).deleteChatMessage(messageId);
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(
        current.copyWith(
          messages: current.messages.where((m) => m.id != messageId).toList(),
        ),
      );
    }
    ref.invalidate(chatThreadListProvider);
  }

  /// メッセージの reaction をトグルする (#612)。ルーム側と共通実装。
  Future<void> toggleReaction(String messageId, String reaction) =>
      _toggleChatReaction(
        ref,
        () => state,
        (v) => state = v,
        messageId,
        reaction,
      );
}

final chatThreadProvider = AsyncNotifierProvider.autoDispose
    .family<ChatThreadNotifier, ChatThreadState, String>(
      ChatThreadNotifier.new,
    );

/// 新規 DM / ルーム招待相手をユーザー検索で探すための provider。
/// 空クエリなら空配列を返す。SearchSupport を持たない adapter でも空配列。
///
/// Misskey の chat (DM / ルーム) は同一サーバー内でのみ成立する仕様のため、
/// `users/search` がリモートユーザーを返してきても同サーバーのみに絞って
/// 表示する。`user.host == null` (local) または現アカウントと同じ host のみ
/// 通す。
final chatUserSearchProvider = FutureProvider.autoDispose
    .family<List<User>, String>((ref, query) async {
      if (query.trim().isEmpty) return const [];
      final adapter = ref.watch(currentAdapterProvider);
      if (adapter is! SearchSupport) return const [];
      final account = ref.watch(currentAccountProvider);
      final selfHost = account?.key.host;
      final users = await (adapter as SearchSupport).searchUsers(
        query,
        limit: 20,
      );
      if (selfHost == null) return users;
      return users.where((u) => u.host == null || u.host == selfHost).toList();
    });

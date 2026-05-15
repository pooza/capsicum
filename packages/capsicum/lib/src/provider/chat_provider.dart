import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'account_manager_provider.dart';
import 'timeline_provider.dart';

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
        e,
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
        e,
        stackTrace: st,
        withScope: (scope) {
          scope.setTag('chat.stream.connect', 'failed');
          scope.fingerprint = ['chat.stream.connect', e.runtimeType.toString()];
        },
      );
    },
    // 再接続上限 (10 回) に到達した時点で 1 回だけ通知される。UI 側で
    // ストリーミング停止を可視化したくなったらここに繋ぐ (#552)。
    onReconnectExhausted: () {
      Sentry.captureMessage(
        'chat.stream.reconnect_exhausted',
        level: SentryLevel.warning,
        withScope: (scope) {
          scope.setTag('chat.stream', 'reconnect_exhausted');
          scope.fingerprint = ['chat.stream.reconnect_exhausted'];
        },
      );
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

    final stream = ref.watch(chatMessageStreamProvider);
    if (stream != null) {
      _streamSub?.cancel();
      _streamSub = stream.listen(_handleStreamMessage);
    }

    return (adapter as ChatSupport).getChatHistory(
      query: const TimelineQuery(limit: 100),
    );
  }

  void _handleStreamMessage(ChatMessage message) {
    final myUserId = ref.read(currentAccountProvider)?.user.id;
    if (myUserId == null) return;
    final isIncoming = message.fromUser.id != myUserId;
    final otherUser = isIncoming ? message.fromUser : message.toUser;
    final current = state.valueOrNull ?? const <ChatThread>[];
    final updated = ChatThread(
      otherUser: otherUser,
      lastMessage: message,
      isUnread: isIncoming && !message.isRead,
    );
    final filtered = current
        .where((t) => t.otherUser.id != otherUser.id)
        .toList();
    state = AsyncData([updated, ...filtered]);
  }
}

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
    // このスレッド (= userId) と関係ないメッセージは無視。
    final relevant =
        message.fromUser.id == userId || message.toUser.id == userId;
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
        try {
          await Sentry.captureException(
            e,
            stackTrace: st,
            withScope: (scope) {
              scope.setTag('chat.load_more', 'failed');
              scope.fingerprint = ['chat.load_more', e.runtimeType.toString()];
            },
          );
        } catch (_) {
          // Sentry 失敗で UI 更新を止めない。
        }
        state = AsyncData(
          (state.valueOrNull ?? current).copyWith(
            isLoadingMore: false,
            loadMoreError: e,
          ),
        );
      }
    }
  }

  Future<ChatMessage> send(String text) async {
    final adapter = ref.read(currentAdapterProvider);
    if (adapter is! ChatSupport) {
      throw StateError('Adapter does not support chat');
    }
    final message = await (adapter as ChatSupport).sendUserMessage(
      userId: arg,
      text: text,
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
}

final chatThreadProvider = AsyncNotifierProvider.autoDispose
    .family<ChatThreadNotifier, ChatThreadState, String>(
      ChatThreadNotifier.new,
    );

/// 新規 DM 相手をユーザー検索で探すための provider。
/// 空クエリなら空配列を返す。SearchSupport を持たない adapter でも空配列。
final chatUserSearchProvider = FutureProvider.autoDispose
    .family<List<User>, String>((ref, query) async {
      if (query.trim().isEmpty) return const [];
      final adapter = ref.watch(currentAdapterProvider);
      if (adapter is! SearchSupport) return const [];
      return (adapter as SearchSupport).searchUsers(query, limit: 20);
    });

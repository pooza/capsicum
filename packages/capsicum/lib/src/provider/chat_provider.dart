import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';
import 'timeline_provider.dart';

/// /chat/history で取得するスレッド一覧。ChatSupport を持たない adapter では
/// 空リストを返す。
class ChatThreadListNotifier
    extends AutoDisposeAsyncNotifier<List<ChatThread>> {
  @override
  Future<List<ChatThread>> build() async {
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter is! ChatSupport) return const [];
    return (adapter as ChatSupport).getChatHistory(
      query: const TimelineQuery(limit: 100),
    );
  }
}

final chatThreadListProvider =
    AsyncNotifierProvider.autoDispose<ChatThreadListNotifier, List<ChatThread>>(
      ChatThreadListNotifier.new,
    );

class ChatThreadState {
  final List<ChatMessage> messages;
  final bool hasMore;
  final bool isLoadingMore;

  const ChatThreadState({
    this.messages = const [],
    this.hasMore = true,
    this.isLoadingMore = false,
  });

  ChatThreadState copyWith({
    List<ChatMessage>? messages,
    bool? hasMore,
    bool? isLoadingMore,
  }) => ChatThreadState(
    messages: messages ?? this.messages,
    hasMore: hasMore ?? this.hasMore,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
  );
}

/// 特定ユーザーとの DM メッセージ一覧。
/// Misskey の /chat/messages/user-timeline は最新→過去の順で返るため、
/// state.messages も「先頭が最新、末尾が古い」順序で保持する。
class ChatThreadNotifier
    extends AutoDisposeFamilyAsyncNotifier<ChatThreadState, String> {
  static const _pageSize = 30;

  @override
  Future<ChatThreadState> build(String arg) async {
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter is! ChatSupport) {
      return const ChatThreadState(hasMore: false);
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

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;
    if (current.messages.isEmpty) return;

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
          ),
        );
        return;
      } catch (_) {
        if (attempt < loadMoreMaxRetries) {
          await Future<void>.delayed(loadMoreRetryDelay);
          continue;
        }
        state = AsyncData(
          (state.valueOrNull ?? current).copyWith(isLoadingMore: false),
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

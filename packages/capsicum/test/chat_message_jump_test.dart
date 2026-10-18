import 'package:capsicum/src/provider/chat_provider.dart';
import 'package:capsicum/src/ui/util/chat_message_jump.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1188: 検索で選んだメッセージの位置へ移る。
///
/// 一覧は新しい順の逆向き `ListView` で高さが決まっていないので、添字では送れ
/// ない。対象が読み込まれるまで続きを引き、組み立てられるまで古い側へ送る。
ChatMessage _message(int n) => ChatMessage(
  id: 'm$n',
  createdAt: DateTime.utc(2026, 10, 18),
  fromUser: const User(id: 'u', username: 'u'),
  // 高さをばらつかせる（添字で送れないことの再現）。
  text: List.filled(1 + n % 4, 'メッセージ $n').join('\n'),
);

class _Host extends StatefulWidget {
  const _Host({required this.total, required this.pageSize, super.key});

  final int total;
  final int pageSize;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with ChatMessageJump {
  final controller = ScrollController();
  late ChatThreadState state = _page(0);
  int loads = 0;

  ChatThreadState _page(int loaded) {
    final count = (loaded + widget.pageSize).clamp(0, widget.total);
    return ChatThreadState(
      messages: [for (var i = 0; i < count; i++) _message(i)],
      hasMore: count < widget.total,
    );
  }

  Future<void> loadMore() async {
    loads++;
    setState(() => state = _page(state.messages.length));
  }

  Future<bool> jump(String id) => jumpToMessage(
    id: id,
    controller: controller,
    read: () => state,
    loadMore: loadMore,
  );

  @override
  void dispose() {
    disposeChatJump();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
    controller: controller,
    reverse: true,
    itemCount: state.messages.length,
    itemBuilder: (context, index) {
      final message = state.messages[index];
      return wrapForJump(
        message.id,
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(message.text!, key: ValueKey(message.id)),
        ),
      );
    },
  );
}

void main() {
  /// [future] が終わるまでフレームを進める。⚠ `runAsync` の中では test の
  /// バインディングがフレームを進めないので、`endOfFrame` の待ちが返らない。
  Future<bool> drive(WidgetTester tester, Future<bool> future) async {
    bool? result;
    future.then((value) => result = value);
    for (var i = 0; i < 2000 && result == null; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(result, isNotNull, reason: '移る処理が終わらない');
    return result!;
  }

  Future<_HostState> pump(WidgetTester tester, {int total = 200}) async {
    final key = GlobalKey<_HostState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _Host(key: key, total: total, pageSize: 30),
        ),
      ),
    );
    return key.currentState!;
  }

  testWidgets('⚠⚠ 読み込まれていない古いメッセージも、続きを引いてそこへ移る', (tester) async {
    final host = await pump(tester);
    expect(find.byKey(const ValueKey('m150')), findsNothing);

    final found = await drive(tester, host.jump('m150'));
    await tester.pumpAndSettle();

    expect(found, isTrue);
    expect(host.loads, greaterThan(0), reason: '続きを引いた');
    expect(find.byKey(const ValueKey('m150')), findsOneWidget, reason: '画面にある');
    // 色を付けている（しばらくで消える）。
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('m150')),
        matching: find.byType(ColoredBox),
      ),
      findsWidgets,
    );
    await tester.pump(kChatJumpHighlight + const Duration(milliseconds: 100));
  });

  testWidgets('上限まで引いても届かなければ false', (tester) async {
    final host = await pump(tester, total: 2000);

    final found = await drive(tester, host.jump('m1999'));

    expect(found, isFalse);
    expect(host.loads, kChatJumpMaxPages);
  });

  testWidgets('存在しない id は、最後まで引いて false', (tester) async {
    final host = await pump(tester, total: 50);

    final found = await drive(tester, host.jump('nope'));

    expect(found, isFalse);
    expect(host.state.hasMore, isFalse);
  });
}

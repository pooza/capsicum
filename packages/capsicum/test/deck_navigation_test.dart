import 'package:capsicum/src/ui/util/deck_navigation.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// #1148: デッキの外（タブ UI）では、今どおり画面遷移する。
///
/// デッキの中の振る舞い（右隣にカラムを足す）は `deck_screen_test` で見る。
void main() {
  final post = Post(
    id: 'p1',
    postedAt: DateTime(2026),
    author: const User(id: 'u1', username: 'alice'),
  );

  Future<void> pumpApp(
    WidgetTester tester,
    void Function(BuildContext context) open,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => open(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/post',
          builder: (context, state) =>
              Text('post:${(state.extra! as Post).id}'),
        ),
        GoRoute(
          path: '/profile',
          builder: (context, state) =>
              Text('profile:${(state.extra! as User).id}'),
        ),
        GoRoute(
          path: '/hashtag/:tag',
          builder: (context, state) =>
              Text('hashtag:${state.pathParameters['tag']}'),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('投稿はスレッド画面へ遷移する', (tester) async {
    await pumpApp(tester, (context) => openPost(context, post));
    expect(find.text('post:p1'), findsOneWidget);
  });

  testWidgets('プロフィールはプロフィール画面へ遷移する', (tester) async {
    await pumpApp(tester, (context) => openProfile(context, post.author));
    expect(find.text('profile:u1'), findsOneWidget);
  });

  testWidgets('ハッシュタグはタグのタイムラインへ遷移する', (tester) async {
    await pumpApp(tester, (context) => openHashtag(context, 'precure_fun'));
    expect(find.text('hashtag:precure_fun'), findsOneWidget);
  });
}

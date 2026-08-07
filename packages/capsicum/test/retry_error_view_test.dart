import 'package:capsicum/src/ui/widget/retry_error_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// #916: 再試行ボタンが「押しても何も起きない」ように見えていた件の共通ビュー。
///
/// riverpod 2.6.1 では、エラー状態の provider を `ref.invalidate` すると
/// `AsyncError` に `isLoading: true` が乗るだけで `AsyncLoading` にはならない。
/// `when` の既定 (`skipLoadingOnRefresh: true`) では error ブランチが再描画
/// されるため、**error ブランチの中で `isLoading` を見て**再取得中を出す。
void main() {
  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  group('RetryErrorView', () {
    testWidgets('通常時は本文と再試行ボタンを出す', (tester) async {
      await tester.pumpWidget(
        host(RetryErrorView(message: '読み込みに失敗しました', onRetry: () {})),
      );

      expect(find.text('読み込みに失敗しました'), findsOneWidget);
      expect(find.text('再試行'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('本文は呼び出し側が組み立てたものをそのまま出す', (tester) async {
      await tester.pumpWidget(
        host(RetryErrorView(message: '読み込みに失敗しました\nboom', onRetry: () {})),
      );

      expect(find.text('読み込みに失敗しました\nboom'), findsOneWidget);
    });

    testWidgets('selectable なら本文をコピーできる（チャット系の従来挙動）', (tester) async {
      await tester.pumpWidget(
        host(
          RetryErrorView(message: 'だめでした', selectable: true, onRetry: () {}),
        ),
      );

      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.byType(Text), findsWidgets);
    });

    testWidgets('押すと onRetry が呼ばれる', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(RetryErrorView(message: 'だめでした', onRetry: () => taps++)),
      );

      await tester.tap(find.text('再試行'));
      expect(taps, 1);
    });

    testWidgets('再取得中はスピナーになりラベルが消える', (tester) async {
      await tester.pumpWidget(
        host(
          RetryErrorView(message: 'だめでした', isRetrying: true, onRetry: () {}),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('再試行'), findsNothing);
    });

    testWidgets('再取得中は連打しても onRetry が呼ばれない', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          RetryErrorView(
            message: 'だめでした',
            isRetrying: true,
            onRetry: () => taps++,
          ),
        ),
      );

      await tester.tap(find.byType(ElevatedButton));
      await tester.tap(find.byType(ElevatedButton));

      expect(taps, 0, reason: '押した数だけ重複リクエストが飛ぶのを止める');
    });

    testWidgets('再取得中でもボタンの寸法が変わらない（押した瞬間に下がずれない）', (tester) async {
      await tester.pumpWidget(
        host(RetryErrorView(message: 'だめでした', onRetry: () {})),
      );
      final idle = tester.getSize(find.byType(ElevatedButton));

      await tester.pumpWidget(
        host(
          RetryErrorView(message: 'だめでした', isRetrying: true, onRetry: () {}),
        ),
      );
      final retrying = tester.getSize(find.byType(ElevatedButton));

      expect(retrying.height, idle.height);
    });
  });

  /// 実際の `AsyncValue` を通した結線。ここが崩れると、画面側が
  /// `isRetrying` に何を渡すべきか分からなくなる。
  group('AsyncValue との結線', () {
    // widget を描かないので `test`。`testWidgets` だと invalidate が仕込む
    // 再取得の timer が「まだ pending」と怒られる（挙動の問題ではない）。
    test('invalidate 直後は AsyncError に isLoading が乗り、error ブランチのまま', () async {
      final provider = FutureProvider<int>((ref) async {
        throw StateError('boom');
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.listen(provider, (_, _) {}, fireImmediately: true);
      await container.read(provider.future).then<void>((_) {}, onError: (_) {});

      final settled = container.read(provider);
      expect(settled.hasError, isTrue);
      expect(settled.isLoading, isFalse);

      container.invalidate(provider);
      final refreshing = container.read(provider);

      expect(
        refreshing.hasError,
        isTrue,
        reason: 'AsyncLoading にはならない（だから when の loading は来ない）',
      );
      expect(
        refreshing.isLoading,
        isTrue,
        reason: 'これを RetryErrorView.isRetrying に渡す',
      );

      // 再取得の失敗を拾っておく（未処理の非同期エラーにしない）。
      await container.read(provider.future).then<void>((_) {}, onError: (_) {});
    });
  });
}

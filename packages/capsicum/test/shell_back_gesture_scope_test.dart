import 'dart:io';

import 'package:capsicum/src/ui/widget/shell_back_gesture_scope.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/dart_source.dart';

/// #1318: デッキで画像を開き、Android の「戻る」ジェスチャーで閉じるとデッキが
/// 解除されてタブ表示に戻る。
///
/// 本物の router と同じ形（shell の中に `/home` と、その上に push する `/deck`・
/// shell の外の root に `/media`）を組み、予測型バックのメッセージを
/// `flutter/backgesture` へ直接流す。⚠ テストの既定の端末は Android。
void main() {
  Future<void> sendBackGesture(WidgetTester tester) async {
    Future<void> send(MethodCall call) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/backgesture',
          const StandardMethodCodec().encodeMethodCall(call),
          (_) {},
        );
    await send(
      const MethodCall('startBackGesture', <String, dynamic>{
        'touchOffset': <double>[5.0, 300.0],
        'progress': 0.0,
        'swipeEdge': 0,
      }),
    );
    await tester.pump();
    await send(
      const MethodCall('updateBackGestureProgress', <String, dynamic>{
        'x': 100.0,
        'y': 300.0,
        'progress': 0.35,
        'swipeEdge': 0,
      }),
    );
    await tester.pump();
    await send(const MethodCall('commitBackGesture'));
    await tester.pumpAndSettle();
  }

  /// [useScope] が false なら修正前の形（shell の builder が素の child を返す）。
  Future<GoRouter> pumpApp(
    WidgetTester tester, {
    required bool useScope,
  }) async {
    final rootKey = GlobalKey<NavigatorState>();
    final shellKey = GlobalKey<NavigatorState>();
    final router = GoRouter(
      navigatorKey: rootKey,
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/media',
          builder: (context, state) => PopScope(
            // 本物の画像ビューアと同じく、戻るを横取りして結果を付けて閉じる。
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) context.pop();
            },
            child: const Scaffold(body: Text('media')),
          ),
        ),
        ShellRoute(
          navigatorKey: shellKey,
          builder: (context, state, child) =>
              useScope ? ShellBackGestureScope(child: child) : child,
          routes: [
            GoRoute(
              path: '/home',
              builder: (_, _) => const Scaffold(body: Text('home')),
            ),
            GoRoute(
              path: '/deck',
              builder: (_, _) => const Scaffold(body: Text('deck')),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.push('/deck');
    await tester.pumpAndSettle();
    expect(find.text('deck'), findsOneWidget);
    return router;
  }

  testWidgets('⚠⚠ 修正前の形では、画像を閉じる「戻る」で下のデッキも閉じる（再現）', (tester) async {
    // ⚠ これが通らなくなったら、Flutter 側の振る舞いが変わって再現しなく
    // なっている。下の「直っている」テストが何も見ていない可能性がある。
    final router = await pumpApp(tester, useScope: false);
    router.push('/media');
    await tester.pumpAndSettle();
    expect(find.text('media'), findsOneWidget);

    await sendBackGesture(tester);

    // ⚠ 積んだ画面は `currentConfiguration.uri` に出ない（push しても base の
    // `/home` のまま）ので、見えているもので判定する。
    expect(
      find.text('deck'),
      findsNothing,
      reason: 'shell の中の /deck が予測型バックを受けて閉じている',
    );
  });

  testWidgets('画像を「戻る」ジェスチャーで閉じると、デッキに戻る', (tester) async {
    final router = await pumpApp(tester, useScope: true);
    router.push('/media');
    await tester.pumpAndSettle();
    expect(find.text('media'), findsOneWidget);

    await sendBackGesture(tester);

    expect(find.text('media'), findsNothing);
    expect(find.text('deck'), findsOneWidget);
  });

  testWidgets('画像を閉じたあとは、デッキ自身の「戻る」ジェスチャーが効く', (tester) async {
    // 差し替えは shell の上に画面が載っている間だけ。戻ったら予測型バックを
    // 返している（デッキから「戻る」でタブ表示へ戻る従来の動き）。
    final router = await pumpApp(tester, useScope: true);
    router.push('/media');
    await tester.pumpAndSettle();
    await sendBackGesture(tester);
    expect(find.text('deck'), findsOneWidget);

    await sendBackGesture(tester);

    expect(find.text('deck'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('ボタンの「戻る」（検出器を通らない）でも、デッキに戻る', (tester) async {
    // 予測型バックの差し替えが、ふつうの戻る（router の popRoute）を壊して
    // いないこと。⚠ 修正前もこちらは起きていなかった（報告どおり）。
    final router = await pumpApp(tester, useScope: true);
    router.push('/media');
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('media'), findsNothing);
    expect(find.text('deck'), findsOneWidget);
  });

  test('本物の router の shell が ShellBackGestureScope で包んでいる', () {
    // ⚠ 上のテストは自前の router を組んでいるので、本物から外れても緑のまま。
    // 外れたら #1318 が戻る。
    final source = maskComments(File('lib/src/router.dart').readAsStringSync());
    final shell = source.indexOf('navigatorKey: shellNavigatorKey');
    expect(shell, isNonNegative, reason: 'shell の ShellRoute が見つからない');
    expect(
      source.substring(shell, shell + 400),
      contains('ShellBackGestureScope(child: child)'),
    );
  });

  group('withoutPredictiveBack', () {
    test('予測型バックの builder だけを置き換える', () {
      const theme = PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
          TargetPlatform.fuchsia:
              PredictiveBackFullscreenPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      );
      final builders = withoutPredictiveBack(theme).builders;
      expect(
        builders[TargetPlatform.android],
        isA<FadeForwardsPageTransitionsBuilder>(),
      );
      expect(
        builders[TargetPlatform.fuchsia],
        isA<ZoomPageTransitionsBuilder>(),
      );
      expect(
        builders[TargetPlatform.iOS],
        isA<CupertinoPageTransitionsBuilder>(),
      );
    });

    test('既定のテーマ（capsicum は上書きしていない）の Android も置き換わる', () {
      final builders = withoutPredictiveBack(
        const PageTransitionsTheme(),
      ).builders;
      expect(
        builders[TargetPlatform.android],
        isA<FadeForwardsPageTransitionsBuilder>(),
      );
    });
  });
}

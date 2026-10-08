import 'package:capsicum/src/ui/widget/notification_bell_button.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// #1196: タブ UI の AppBar でベルにツールチップが出ていなかった。
///
/// ⚠⚠ **素直に `IconButton.tooltip` を付けると長押しメニューが壊れる。**
/// built-in の `Tooltip` が `LongPressGestureRecognizer` を足し、外側の
/// `GestureDetector.onLongPress`（アカウント選択）から長押しを奪う。だから
/// 複数アカウント時は `tooltip: null` にしてあった、という経緯がある。
///
/// ⚠⚠ **両立の鍵は `Tooltip` を `GestureDetector` の外側に置くこと。**built-in
/// tooltip は `IconButton` の中（＝内側）に入るので arena で内側が勝ってしまう。
/// 外側なら内側のメニューが勝つ。**これは実測した** —— built-in tooltip の形へ
/// 戻すと、下の「長押しメニューは出る」が落ちる。
///
/// ⚠ `triggerMode: manual` は保険。既定の `longPress` でも**いまは通る**ので
/// 振る舞いだけでは噛まない。登録順に依存する競りを消すための意図なので、
/// **選択そのものを固定する**検査を別に置いてある。
///
/// ⚠ **この 2 つ（ホバーで出る・長押しでメニューが出る）を同時に固定する**のが
/// このファイルの仕事で、片方だけでは守りにならない。
void main() {
  /// ベル 1 つだけを置いた画面を立てる。
  ///
  /// ⚠ `context.push` を呼ぶので `GoRouter` が要る。遷移先は中身を見ないので
  /// 文字列だけ置いて、押された経路を [pushed] に記録する。
  Future<List<String>> pumpBell(
    WidgetTester tester, {
    required bool hasMultipleAccounts,
  }) async {
    final pushed = <String>[];
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) => Scaffold(
            appBar: AppBar(
              actions: [
                NotificationBellButton(
                  hasMultipleAccounts: hasMultipleAccounts,
                ),
              ],
            ),
          ),
        ),
        for (final path in ['/notifications', '/notifications/all'])
          GoRoute(
            path: path,
            builder: (_, _) {
              pushed.add(path);
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    return pushed;
  }

  /// ホバーして（デスクトップでの出し方）ツールチップの文面を探す。
  Future<void> hoverBell(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(() => mouse.removePointer());
    await mouse.addPointer(location: Offset.zero);
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.byType(NotificationBellButton)));
    await tester.pumpAndSettle();
  }

  group('複数アカウント（長押しメニューがある）', () {
    testWidgets('⚠⚠ ホバーでツールチップが出る', (tester) async {
      await pumpBell(tester, hasMultipleAccounts: true);

      await hoverBell(tester);

      expect(find.text('通知（長押しでアカウントを選択）'), findsOneWidget);
    });

    testWidgets('⚠⚠ ツールチップを巻いても長押しメニューは出る', (tester) async {
      await pumpBell(tester, hasMultipleAccounts: true);

      await tester.longPress(find.byType(NotificationBellButton));
      await tester.pumpAndSettle();

      expect(
        find.text('すべての通知'),
        findsOneWidget,
        reason: '⚠⚠ Tooltip が長押しを奪うと、ここが findsNothing になる',
      );
      expect(find.text('このアカウントの通知'), findsOneWidget);
    });

    // ⚠⚠ **これが上の検査の裏側。**built-in tooltip へ戻すと長押しが奪われる
    // ので、「付いていないこと」自体を固定する。⚠ 素直に `tooltip:` を書き足す
    // のが**いちばん起きそうな壊し方**（実際そうやって一度壊れていた）。
    testWidgets('⚠⚠ built-in tooltip は使わない（長押しを奪うため）', (tester) async {
      await pumpBell(tester, hasMultipleAccounts: true);

      expect(
        tester.widget<IconButton>(find.byType(IconButton)).tooltip,
        isNull,
        reason: '⚠⚠ ここに文字列を入れると、長押しメニューが出なくなる',
      );
    });

    // ⚠ 既定の `longPress` でも振る舞いは通ってしまうので、**選択を固定する**。
    // 両者の LongPressGestureRecognizer が同じ deadline で競り、どちらが arena
    // を取るかが登録順に依存するため、競り自体を消しておきたい。
    testWidgets('⚠ Tooltip の trigger は manual（競りを起こさない）', (tester) async {
      await pumpBell(tester, hasMultipleAccounts: true);

      expect(
        tester.widget<Tooltip>(find.byType(Tooltip)).triggerMode,
        TooltipTriggerMode.manual,
        reason: '⚠ 既定だと long-press の recognizer が増え、メニューと競る',
      );
    });

    testWidgets('タップはまとめ画面へ（#345・対照群）', (tester) async {
      final pushed = await pumpBell(tester, hasMultipleAccounts: true);

      await tester.tap(find.byType(NotificationBellButton));
      await tester.pumpAndSettle();

      expect(pushed, ['/notifications/all']);
    });
  });

  group('単一アカウント（長押しメニューが無い）', () {
    // ⚠ こちらは built-in tooltip のままでよい。奪われる相手が居ないので、
    // タッチでの長押しでもツールチップが出るぶん built-in のほうが強い。
    testWidgets('⚠ built-in のツールチップが付いている', (tester) async {
      await pumpBell(tester, hasMultipleAccounts: false);

      expect(tester.widget<IconButton>(find.byType(IconButton)).tooltip, '通知');
    });

    testWidgets('タップはこのアカウントの通知へ（対照群）', (tester) async {
      final pushed = await pumpBell(tester, hasMultipleAccounts: false);

      await tester.tap(find.byType(NotificationBellButton));
      await tester.pumpAndSettle();

      expect(pushed, ['/notifications']);
    });
  });
}

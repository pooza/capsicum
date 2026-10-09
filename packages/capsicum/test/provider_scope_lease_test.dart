import 'dart:io';

import 'package:capsicum/src/ui/util/provider_scope_carrier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1235: push 先の画面に渡したコンテナは、その画面が閉じるまで破棄されない。
///
/// ⚠⚠ **デッキ画面は、列に居なくなったアカウントのコンテナを破棄する。**別
/// アカウントのカラムから投稿フォームを開いたままアカウントが切り替わると、
/// スタックに残ったフォームが破棄済みのコンテナを読んで StateError を投げて
/// いた（本文を書いている最中に起きる）。
final _value = Provider<int>((ref) => 42);

void main() {
  bool isDisposed(ProviderContainer container) {
    try {
      container.read(_value);
      return false;
    } on StateError {
      return true;
    }
  }

  Widget leased(ProviderContainer container, {Key? key}) => KeyedSubtree(
    key: key,
    child: withExtraProviderScope({
      providerScopeExtraKey: container,
    }, Consumer(builder: (_, ref, _) => Text('${ref.watch(_value)}'))),
  );

  testWidgets('⚠⚠ 貸している間は、持ち主が手放しても破棄されない', (tester) async {
    final container = ProviderContainer();
    await tester.pumpWidget(MaterialApp(home: leased(container)));
    expect(ProviderScopeLeases.isLeased(container), isTrue);

    // デッキ画面が「未使用」と判断して手放した。
    ProviderScopeLeases.disposeWhenReleased(container);
    await tester.pump();

    expect(isDisposed(container), isFalse, reason: '開いたままの画面が次の read で落ちる');
    expect(find.text('42'), findsOneWidget);

    // 画面が閉じたら片づく。
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    expect(ProviderScopeLeases.isLeased(container), isFalse);
    expect(isDisposed(container), isTrue, reason: '借り手が居なくなったのに残り続ける');
  });

  testWidgets('貸していなければ、手放した時点で破棄する（従来どおり）', (tester) async {
    final container = ProviderContainer();

    ProviderScopeLeases.disposeWhenReleased(container);

    expect(isDisposed(container), isTrue);
  });

  testWidgets('借り手が 2 つあれば、最後の 1 つが閉じるまで破棄しない', (tester) async {
    final container = ProviderContainer();
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            leased(container, key: const ValueKey('a')),
            leased(container, key: const ValueKey('b')),
          ],
        ),
      ),
    );
    ProviderScopeLeases.disposeWhenReleased(container);

    await tester.pumpWidget(
      MaterialApp(
        home: Column(children: [leased(container, key: const ValueKey('a'))]),
      ),
    );
    await tester.pump();
    expect(isDisposed(container), isFalse);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(isDisposed(container), isTrue);
  });

  testWidgets('持ち主が手放さなければ、画面が閉じても破棄しない', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(MaterialApp(home: leased(container)));

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    expect(isDisposed(container), isFalse, reason: 'カラムがまだ使っているコンテナを捨ててしまう');
  });

  /// 台帳が正しくても、デッキ画面が素の `dispose()` を呼べば素通りする。
  test('デッキ画面はコンテナを台帳経由で手放している', () {
    final src = File('lib/src/ui/screen/deck_screen.dart').readAsStringSync();
    expect(
      'ProviderScopeLeases.disposeWhenReleased('.allMatches(src).length,
      2,
      reason: '列から居なくなったとき / 画面を閉じるとき、の 2 か所',
    );
    expect(
      src,
      isNot(contains('container.dispose()')),
      reason: '貸しているコンテナを数えずに破棄している',
    );
  });
}

import 'package:capsicum/src/ui/widget/stacked_avatars.dart';
import 'package:capsicum/src/ui/widget/user_avatar.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1048: 束ねた通知の代表アカウントを重ねて出す。
///
/// ⚠ **横に並べるとカラム（320px）で名前が消える**ので、重ねた幅であることを
/// 固定する。
void main() {
  List<User> users(int count) => [
    for (var i = 0; i < count; i++) User(id: '$i', username: 'u$i'),
  ];

  Future<Size> pump(WidgetTester tester, List<User> list) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: StackedAvatars(users: list),
            ),
          ),
        ),
      ),
    );
    return tester.getSize(find.byType(StackedAvatars));
  }

  testWidgets('1 人なら 1 枚ぶんの幅', (tester) async {
    expect((await pump(tester, users(1))).width, 24);
  });

  testWidgets('4 人でも重なるので 60px（素に並べると 96px）', (tester) async {
    expect((await pump(tester, users(4))).width, 60);
  });

  testWidgets('⚠ maxCount を超えたぶんは描かない（人数は見出しの文字列が持つ）', (tester) async {
    final size = await pump(tester, users(8));
    expect(size.width, 60);
    expect(find.byType(UserAvatar), findsNWidgets(4));
  });

  testWidgets('空でも幅を持つ（見出しの並びが崩れない）', (tester) async {
    expect((await pump(tester, users(0))).width, 24);
    expect(find.byType(UserAvatar), findsNothing);
  });

  testWidgets('⚠ 先頭が一番手前（押せるのは先頭だけ）', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: StackedAvatars(
                users: users(3),
                onTapFirst: () => tapped.add('first'),
              ),
            ),
          ),
        ),
      ),
    );
    // 先頭のアイコンの中心は left:0 側。重なりの一番手前に居るので拾える。
    await tester.tapAt(
      tester.getTopLeft(find.byType(StackedAvatars)) + const Offset(6, 12),
    );
    expect(tapped, ['first']);
  });
}

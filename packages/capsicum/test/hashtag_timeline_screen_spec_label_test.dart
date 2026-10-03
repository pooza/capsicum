import 'package:capsicum/src/ui/screen/hashtag_timeline_screen.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1159: タグ TL の画面は spec（エスケープ済みの内部表現）を受け取る。
///
/// ⚠⚠ **実機検証で見つかった取りこぼし**（2026-09-21）。検索から `c++` を
/// 開くと、見出しが `#c%2B%2B` になっていた。同じ spec を投稿欄とフォローにも
/// 素のまま渡していたので、**存在しないタグで投稿・フォローしてしまう**。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpScreen(WidgetTester tester, String spec) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: HashtagTimelineScreen(hashtag: spec)),
      ),
    );
    await tester.pump();
  }

  testWidgets('⚠⚠ 見出しはエスケープを戻したタグ名で出す（#c%2B%2B にしない）', (tester) async {
    await pumpScreen(tester, hashtagSpecFromTag('c++'));

    expect(find.text('#c++'), findsOneWidget);
    expect(find.textContaining('%2B'), findsNothing);
  });

  testWidgets('AND 指定はタブ名と同じ形で出す', (tester) async {
    await pumpScreen(tester, hashtagSpecFromTags(['nitiasa', 'c++']));

    expect(find.text('#nitiasa + #c++'), findsOneWidget);
  });
}

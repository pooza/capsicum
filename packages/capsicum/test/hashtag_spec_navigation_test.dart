import 'package:capsicum/src/provider/hashtag_provider.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// #1159: `+` を含むタグを URL に載せて往復できること。
///
/// ⚠⚠ **go_router はパスパラメータを URL デコードする。**spec の `%2B` を素の
/// まま `/hashtag/<spec>` へ置くと、受け取る側では `+` に戻って **AND 指定として
/// 割れる**。⚠ だから `openHashtag` は **spec をもう一度エスケープして**押し込む。
/// ここではその前提（デコードされること）と、往復が成立することの両方を実測で
/// 固定する。
void main() {
  /// `/hashtag/:tag` へ [location] で入ったとき、画面が受け取る値。
  Future<String> tagParamFor(WidgetTester tester, String location) async {
    late String received;
    final router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(
          path: '/hashtag/:tag',
          builder: (context, state) {
            received = state.pathParameters['tag']!;
            return const SizedBox();
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    return received;
  }

  testWidgets('⚠⚠ go_router はパスパラメータをデコードする（素の %2B は + に戻る）', (tester) async {
    expect(
      await tagParamFor(tester, '/hashtag/c%2B%2B'),
      'c++',
      reason: '⚠ この前提が変わったら openHashtag の二重エスケープを見直すこと',
    );
  });

  testWidgets('⚠ spec を二重にエスケープすれば、spec のまま受け取れる', (tester) async {
    final spec = hashtagSpecFromTag('c++');
    final received = await tagParamFor(
      tester,
      '/hashtag/${Uri.encodeComponent(spec)}',
    );

    expect(received, spec);
    expect(hashtagSpecTags(received), [
      'c++',
    ], reason: '⚠⚠ 画面が組み立てる HashtagTab が元のタグ 1 つを指す');
  });

  testWidgets('ふつうのタグ・日本語のタグも往復する', (tester) async {
    for (final tag in ['precure_fun', 'ダイの大冒険']) {
      final spec = hashtagSpecFromTag(tag);
      final received = await tagParamFor(
        tester,
        '/hashtag/${Uri.encodeComponent(spec)}',
      );
      expect(hashtagSpecTags(received), [tag]);
    }
  });

  test('AND 指定の spec も往復し、表示ラベルになる', () {
    final spec = hashtagSpecFromTags(['nitiasa', 'precure']);
    final (primary, all) = parseHashtagSpec(spec);
    expect(primary, 'nitiasa');
    expect(all, ['precure']);
    expect(hashtagSpecLabel(spec), '#nitiasa + #precure');
  });

  test('⚠ `+` を含むタグのラベルは 1 つのタグとして出る', () {
    final spec = hashtagSpecFromTag('c++');
    expect(hashtagSpecLabel(spec), '#c++');
    final (primary, all) = parseHashtagSpec(spec);
    expect(primary, 'c++');
    expect(all, isNull, reason: '⚠ AND 条件として扱わない');
  });
}

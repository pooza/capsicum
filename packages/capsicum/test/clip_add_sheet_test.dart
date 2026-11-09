import 'package:capsicum/src/ui/widget/clip_add_sheet.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1050: 投稿の「クリップに追加」のシート。
///
/// ⚠⚠ 印は「分かる分だけ」（2026-11-10 pooza）。Misskey の `notes/clips` は
/// 公開のクリップしか返さないので、非公開のクリップには前もって印が付かない。
/// 押して「もう入っている」が返ったら、Web と同じく外すかを尋ねる。
class _Adapter extends Mock
    implements
        DecentralizedBackendAdapter,
        ClipSupport,
        ClipManagementSupport {}

const _public = NoteClip(id: 'pub', name: '公開のクリップ', isPublic: true);
const _private = NoteClip(id: 'priv', name: '非公開のクリップ');

final _post = Post(
  id: 'n1',
  postedAt: DateTime.utc(2026, 11, 10),
  author: const User(id: 'u1', username: 'alice'),
);

void main() {
  late _Adapter adapter;

  setUp(() {
    adapter = _Adapter();
    when(() => adapter.getClips()).thenAnswer((_) async => [_public, _private]);
    when(() => adapter.addNoteToClip(any(), any())).thenAnswer((_) async {});
    when(
      () => adapter.removeNoteFromClip(any(), any()),
    ).thenAnswer((_) async {});
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ClipAddSheet(
            post: _post,
            clips: adapter,
            manage: adapter,
            account: null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder rowIcon(String name, IconData icon) => find.descendant(
    of: find.widgetWithText(ListTile, name),
    matching: find.byIcon(icon),
  );

  testWidgets('入っていると分かった自分の公開クリップにだけ印を付ける', (tester) async {
    // ほかの人のクリップ（other）は自分の一覧に無いので数えない。
    when(
      () => adapter.getPublicClipIdsContaining('n1'),
    ).thenAnswer((_) async => {'pub', 'other'});
    await pump(tester);

    expect(rowIcon('公開のクリップ', Icons.check_circle), findsOneWidget);
    expect(rowIcon('非公開のクリップ', Icons.circle_outlined), findsOneWidget);
  });

  testWidgets('⚠ 入っているかが分からなくても、シートは使える', (tester) async {
    when(
      () => adapter.getPublicClipIdsContaining('n1'),
    ).thenThrow(Exception('boom'));
    await pump(tester);

    expect(find.text('公開のクリップ'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('印の無いクリップを押すと入れ、印を付ける', (tester) async {
    when(
      () => adapter.getPublicClipIdsContaining('n1'),
    ).thenAnswer((_) async => {});
    await pump(tester);

    await tester.tap(find.text('非公開のクリップ'));
    await tester.pumpAndSettle();

    verify(() => adapter.addNoteToClip('priv', 'n1')).called(1);
    expect(rowIcon('非公開のクリップ', Icons.check_circle), findsOneWidget);
    expect(find.text('「非公開のクリップ」に入れました'), findsOneWidget);
  });

  testWidgets('印の付いたクリップを押すと外す', (tester) async {
    when(
      () => adapter.getPublicClipIdsContaining('n1'),
    ).thenAnswer((_) async => {'pub'});
    await pump(tester);

    await tester.tap(find.text('公開のクリップ'));
    await tester.pumpAndSettle();

    verify(() => adapter.removeNoteFromClip('pub', 'n1')).called(1);
    verifyNever(() => adapter.addNoteToClip(any(), any()));
    expect(rowIcon('公開のクリップ', Icons.circle_outlined), findsOneWidget);
  });

  group('⚠⚠ 印の無いクリップに、もう入っていた', () {
    setUp(() {
      when(
        () => adapter.getPublicClipIdsContaining('n1'),
      ).thenAnswer((_) async => {});
      when(
        () => adapter.addNoteToClip('priv', 'n1'),
      ).thenThrow(const AlreadyClipped());
    });

    testWidgets('外すかを尋ね、「外す」なら外す', (tester) async {
      await pump(tester);

      await tester.tap(find.text('非公開のクリップ'));
      await tester.pumpAndSettle();
      expect(find.text('この投稿は「非公開のクリップ」に入っています。外しますか？'), findsOneWidget);

      await tester.tap(find.text('外す'));
      await tester.pumpAndSettle();

      verify(() => adapter.removeNoteFromClip('priv', 'n1')).called(1);
      expect(rowIcon('非公開のクリップ', Icons.circle_outlined), findsOneWidget);
    });

    testWidgets('「そのまま」なら外さず、入っている印を付ける', (tester) async {
      await pump(tester);

      await tester.tap(find.text('非公開のクリップ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('そのまま'));
      await tester.pumpAndSettle();

      verifyNever(() => adapter.removeNoteFromClip(any(), any()));
      expect(rowIcon('非公開のクリップ', Icons.check_circle), findsOneWidget);
    });
  });

  testWidgets('1 つのクリップの上限に当たったら、シートの中で知らせる', (tester) async {
    when(
      () => adapter.getPublicClipIdsContaining('n1'),
    ).thenAnswer((_) async => {});
    when(
      () => adapter.addNoteToClip('priv', 'n1'),
    ).thenThrow(const ClipNoteLimitReached());
    await pump(tester);

    await tester.tap(find.text('非公開のクリップ'));
    await tester.pumpAndSettle();

    expect(find.text('「非公開のクリップ」には、これ以上入れられません'), findsOneWidget);
    expect(rowIcon('非公開のクリップ', Icons.circle_outlined), findsOneWidget);
  });
}

// #1053: ギャラリーの閲覧の充実（段階 1）。新着の一覧と、詳細のいいね。
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/ui/screen/gallery_detail_screen.dart';
import 'package:capsicum/src/ui/screen/gallery_screen.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _GalleryAdapter extends Mock
    implements DecentralizedBackendAdapter, GallerySupport {}

GalleryPost _post(String id, {bool? isLiked, int likedCount = 2}) =>
    GalleryPost(
      id: id,
      title: 'title-$id',
      author: const User(id: 'u1', username: 'alice'),
      files: const [],
      createdAt: DateTime(2026, 11, 1),
      likedCount: likedCount,
      isLiked: isLiked,
    );

DioException _misskeyError(String code, {int status = 400}) {
  final options = RequestOptions(path: '/api/gallery/posts/like');
  return DioException(
    requestOptions: options,
    response: Response(
      requestOptions: options,
      statusCode: status,
      data: {
        'error': {'code': code},
      },
    ),
  );
}

void main() {
  late _GalleryAdapter adapter;

  setUpAll(() {
    registerFallbackValue(const TimelineQuery());
  });

  setUp(() => adapter = _GalleryAdapter());

  Future<void> pumpDetail(WidgetTester tester, GalleryPost post) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [currentAdapterProvider.overrideWithValue(adapter)],
        child: MaterialApp(home: GalleryDetailScreen(post: post)),
      ),
    );
    await tester.pumpAndSettle();
  }

  final like = find.byKey(const ValueKey('gallery-like'));

  group('詳細のいいね', () {
    testWidgets('押すといいねになり、数が 1 増える', (tester) async {
      when(() => adapter.likeGalleryPost(any())).thenAnswer((_) async {});
      await pumpDetail(tester, _post('p1', isLiked: false));
      expect(find.text('2'), findsOneWidget);

      await tester.tap(like);
      await tester.pumpAndSettle();

      verify(() => adapter.likeGalleryPost('p1')).called(1);
      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('いいね済みなら取り消しを送る', (tester) async {
      when(() => adapter.unlikeGalleryPost(any())).thenAnswer((_) async {});
      await pumpDetail(tester, _post('p1', isLiked: true));

      await tester.tap(like);
      await tester.pumpAndSettle();

      verify(() => adapter.unlikeGalleryPost('p1')).called(1);
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('⚠ ALREADY_LIKED は成功扱い（戻さない・知らせない）', (tester) async {
      when(
        () => adapter.likeGalleryPost(any()),
      ).thenThrow(_misskeyError('ALREADY_LIKED'));
      await pumpDetail(tester, _post('p1'));

      await tester.tap(like);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      // ⚠ もともといいね済みだった＝件数には含まれている。足さない（#1420）。
      expect(find.text('2'), findsOneWidget);
    });

    // #1420: 一覧の投稿は取得した時点のまま。詳細で変えたものを開き直しで失わない。
    testWidgets('⚠⚠ いいねして閉じ、同じ（古い）投稿で開き直しても、いいね済みで出る', (tester) async {
      when(() => adapter.likeGalleryPost(any())).thenAnswer((_) async {});
      final stale = _post('p1', isLiked: false);
      final open = ValueNotifier(true);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [currentAdapterProvider.overrideWithValue(adapter)],
          child: MaterialApp(
            home: ValueListenableBuilder<bool>(
              valueListenable: open,
              builder: (_, isOpen, _) => isOpen
                  ? GalleryDetailScreen(key: UniqueKey(), post: stale)
                  : const SizedBox(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(like);
      await tester.pumpAndSettle();
      open.value = false;
      await tester.pumpAndSettle();
      open.value = true;
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('自分の投稿（YOUR_POST）は戻して専用の文言', (tester) async {
      when(
        () => adapter.likeGalleryPost(any()),
      ).thenThrow(_misskeyError('YOUR_POST'));
      await pumpDetail(tester, _post('p1', isLiked: false));

      await tester.tap(like);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('自分のギャラリー投稿にはいいねできません'), findsOneWidget);
    });
  });

  group('一覧の人気 / 新着', () {
    testWidgets('既定は人気。新着に切り替えると gallery/posts を引く', (tester) async {
      when(
        () => adapter.getGalleryPosts(query: any(named: 'query')),
      ).thenAnswer((_) async => [_post('f1')]);
      when(
        () => adapter.getRecentGalleryPosts(query: any(named: 'query')),
      ).thenAnswer((_) async => [_post('r1')]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [currentAdapterProvider.overrideWithValue(adapter)],
          child: const MaterialApp(home: GalleryScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('title-f1'), findsOneWidget);
      verifyNever(
        () => adapter.getRecentGalleryPosts(query: any(named: 'query')),
      );

      await tester.tap(find.text('新着'));
      await tester.pumpAndSettle();

      expect(find.text('title-r1'), findsOneWidget);
      expect(find.text('title-f1'), findsNothing);
    });
  });
}

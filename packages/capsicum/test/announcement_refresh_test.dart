import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/announcement_provider.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #888: 新しいお知らせがアカウントを切り替えるまで反映されない問題への対処。
///
/// 常駐ポーリングは持たず、「フォアグラウンド復帰 / お知らせ画面を開いた /
/// streaming で受信」の各機会に [AnnouncementNotifier.refresh] で取り直す。
/// ここでは refresh の性質（ローディングに落とさない・失敗しても現状維持）を
/// 固める。表示中の一覧が一瞬消えると、取り直しのたびにちらつくため。
class _FakeAdapter extends Mock
    implements DecentralizedBackendAdapter, AnnouncementSupport {
  _FakeAdapter(this.server);

  List<Announcement> server;
  bool fail = false;
  int fetchCount = 0;

  @override
  Future<List<Announcement>> getAnnouncements() async {
    fetchCount++;
    if (fail) throw Exception('server down');
    return server;
  }
}

Announcement _ann(String id) => Announcement(
  id: id,
  content: 'body $id',
  publishedAt: DateTime.utc(2026, 7, 31),
);

Future<(ProviderContainer, AnnouncementNotifier)> _boot(
  _FakeAdapter adapter,
) async {
  final container = ProviderContainer(
    overrides: [currentAdapterProvider.overrideWithValue(adapter)],
  );
  addTearDown(container.dispose);
  await container.read(announcementProvider.future);
  return (container, container.read(announcementProvider.notifier));
}

void main() {
  test('refresh でサーバー側の新しいお知らせが反映される', () async {
    final adapter = _FakeAdapter([_ann('1')]);
    final (container, notifier) = await _boot(adapter);

    adapter.server = [_ann('2'), _ann('1')];
    await notifier.refresh();

    final ids = container
        .read(announcementProvider)
        .value!
        .announcements
        .map((a) => a.id);
    expect(ids, ['2', '1']);
  });

  test('refresh はローディングに落とさない（一覧が一瞬消えない）', () async {
    final adapter = _FakeAdapter([_ann('1')]);
    final (container, notifier) = await _boot(adapter);

    final future = notifier.refresh();
    // 取得の最中でも直前の一覧が見えたままであること。
    expect(container.read(announcementProvider).isLoading, isFalse);
    expect(
      container.read(announcementProvider).value!.announcements,
      hasLength(1),
    );

    await future;
    expect(container.read(announcementProvider).isLoading, isFalse);
  });

  test('取得に失敗しても現状維持（お知らせは補助情報なので落とさない）', () async {
    final adapter = _FakeAdapter([_ann('1')]);
    final (container, notifier) = await _boot(adapter);

    adapter.fail = true;
    await notifier.refresh();

    expect(container.read(announcementProvider).hasError, isFalse);
    final ids = container
        .read(announcementProvider)
        .value!
        .announcements
        .map((a) => a.id);
    expect(ids, ['1']);
  });

  test('お知らせ非対応の adapter では取得しない', () async {
    final container = ProviderContainer(
      overrides: [currentAdapterProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    await container.read(announcementProvider.future);

    await container.read(announcementProvider.notifier).refresh();

    expect(container.read(announcementProvider).value!.announcements, isEmpty);
  });
}

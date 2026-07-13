import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/announcement_provider.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #819 お知らせリアクションの付け外し（楽観更新 → サーバー権威値で reconcile、
/// 失敗時ロールバック）を検証する。
///
/// [server] がサーバー側の権威状態。add/remove は本物の Mastodon と同様に
/// server を更新し、getAnnouncements はその server を返すため、成功時は最終
/// state が server と一致する。
class _FakeAdapter extends Mock
    implements
        DecentralizedBackendAdapter,
        AnnouncementSupport,
        AnnouncementReactionSupport {
  List<Announcement> server;
  bool failReaction = false;

  _FakeAdapter(this.server);

  @override
  Future<List<Announcement>> getAnnouncements() async => server;

  @override
  Future<void> addAnnouncementReaction(String id, String name) async {
    if (failReaction) throw Exception('rate limited');
    _mutate(id, name, add: true);
  }

  @override
  Future<void> removeAnnouncementReaction(String id, String name) async {
    if (failReaction) throw Exception('rate limited');
    _mutate(id, name, add: false);
  }

  void _mutate(String id, String name, {required bool add}) {
    server = server.map((a) {
      if (a.id != id) return a;
      final reactions = [...a.reactions];
      final idx = reactions.indexWhere((r) => r.name == name);
      if (add) {
        if (idx >= 0) {
          reactions[idx] = reactions[idx].copyWith(
            count: reactions[idx].count + 1,
            me: true,
          );
        } else {
          reactions.add(AnnouncementReaction(name: name, count: 1, me: true));
        }
      } else if (idx >= 0) {
        if (reactions[idx].count <= 1) {
          reactions.removeAt(idx);
        } else {
          reactions[idx] = reactions[idx].copyWith(
            count: reactions[idx].count - 1,
            me: false,
          );
        }
      }
      return a.copyWith(reactions: reactions);
    }).toList();
  }
}

Announcement _ann(String id, List<AnnouncementReaction> reactions) => Announcement(
  id: id,
  content: 'body',
  publishedAt: DateTime(2026, 7, 13),
  reactions: reactions,
);

Future<(ProviderContainer, AnnouncementNotifier)> _boot(
  _FakeAdapter adapter,
) async {
  final container = ProviderContainer(
    overrides: [currentAdapterProvider.overrideWithValue(adapter)],
  );
  addTearDown(container.dispose);
  // build() が getAnnouncements を読むまで待つ。
  await container.read(announcementProvider.future);
  return (container, container.read(announcementProvider.notifier));
}

AnnouncementReaction _reactionOf(
  ProviderContainer container,
  String id,
  String name,
) {
  final anns = container.read(announcementProvider).value!.announcements;
  final ann = anns.firstWhere((a) => a.id == id);
  return ann.reactions.firstWhere((r) => r.name == name);
}

bool _hasReaction(ProviderContainer container, String id, String name) {
  final anns = container.read(announcementProvider).value!.announcements;
  final ann = anns.firstWhere((a) => a.id == id);
  return ann.reactions.any((r) => r.name == name);
}

void main() {
  test('新規リアクション付与: 最終 state に me=true・count=1 で載る', () async {
    final adapter = _FakeAdapter([_ann('1', const [])]);
    final (container, notifier) = await _boot(adapter);

    await notifier.toggleReaction('1', '👍', add: true);

    final r = _reactionOf(container, '1', '👍');
    expect(r.count, 1);
    expect(r.me, isTrue);
  });

  test('既存リアクションへの相乗り: count+1・me=true', () async {
    final adapter = _FakeAdapter([
      _ann('1', const [AnnouncementReaction(name: '👍', count: 2, me: false)]),
    ]);
    final (container, notifier) = await _boot(adapter);

    await notifier.toggleReaction('1', '👍', add: true);

    final r = _reactionOf(container, '1', '👍');
    expect(r.count, 3);
    expect(r.me, isTrue);
  });

  test('自分の最後のリアクション除去: チップごと消える', () async {
    final adapter = _FakeAdapter([
      _ann('1', const [AnnouncementReaction(name: '👍', count: 1, me: true)]),
    ]);
    final (container, notifier) = await _boot(adapter);

    await notifier.toggleReaction('1', '👍', add: false);

    expect(_hasReaction(container, '1', '👍'), isFalse);
  });

  test('API 失敗時はロールバックして元の状態に戻る', () async {
    final adapter = _FakeAdapter([_ann('1', const [])])..failReaction = true;
    final (container, notifier) = await _boot(adapter);

    await expectLater(
      notifier.toggleReaction('1', '👍', add: true),
      throwsA(isA<Exception>()),
    );

    expect(_hasReaction(container, '1', '👍'), isFalse);
  });

  test('リアクション非対応アダプタでは何もしない（例外を投げない）', () async {
    // AnnouncementReactionSupport を実装しない素の AnnouncementSupport 相当。
    final adapter = _NonReactionAdapter([_ann('1', const [])]);
    final container = ProviderContainer(
      overrides: [currentAdapterProvider.overrideWithValue(adapter)],
    );
    addTearDown(container.dispose);
    await container.read(announcementProvider.future);

    // 例外を投げず no-op で返る。
    await container
        .read(announcementProvider.notifier)
        .toggleReaction('1', '👍', add: true);

    final anns = container.read(announcementProvider).value!.announcements;
    expect(anns.first.reactions, isEmpty);
  });
}

class _NonReactionAdapter extends Mock
    implements DecentralizedBackendAdapter, AnnouncementSupport {
  final List<Announcement> server;
  _NonReactionAdapter(this.server);

  @override
  Future<List<Announcement>> getAnnouncements() async => server;
}

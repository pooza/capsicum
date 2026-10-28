import 'package:capsicum/src/model/account.dart';
import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/notification_provider.dart';
import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/service/announcement_subscription_service.dart';
import 'package:capsicum/src/ui/util/notification_detail_text.dart';
import 'package:capsicum/src/ui/widget/notification_filter_button.dart';
import 'package:capsicum/src/util/announcement_notifications.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1308: 通知のタイムラインにお知らせを含める（2026-10-27 pooza 判断）。
Notification _mention(String id, DateTime at) => Notification(
  id: id,
  type: NotificationType.mention,
  createdAt: at,
  user: const User(id: 'u', username: 'someone'),
);

Announcement _announcement(
  String id,
  DateTime at, {
  String content = '本文',
  String? title,
  bool isHtml = false,
  DateTime? updatedAt,
  bool read = false,
}) => Announcement(
  id: id,
  content: content,
  title: title,
  isHtml: isHtml,
  publishedAt: at,
  updatedAt: updatedAt,
  read: read,
);

DateTime _at(int hour) => DateTime.utc(2026, 10, 27, hour);

class _Adapter extends Mock
    implements
        DecentralizedBackendAdapter,
        NotificationSupport,
        AnnouncementSupport {
  _Adapter(this.all, this.announcements);

  /// 新しい順。
  final List<Notification> all;
  final List<Announcement> announcements;
  bool failAnnouncements = false;
  final requestedMaxIds = <String?>[];

  @override
  Set<NotificationType> get filterableNotificationTypes => {
    NotificationType.mention,
  };

  @override
  Future<NotificationResponse> getNotifications({
    TimelineQuery? query,
    NotificationQuery? filter,
  }) async {
    final maxId = query?.maxId;
    requestedMaxIds.add(maxId);
    final start = maxId == null ? 0 : all.indexWhere((n) => n.id == maxId) + 1;
    final page = all.skip(start).take(query?.limit ?? 20).toList();
    return NotificationResponse(
      notifications: page,
      rawCount: page.length,
      rawLastId: page.lastOrNull?.id,
    );
  }

  @override
  Future<List<Announcement>> getAnnouncements() async {
    if (failAnnouncements) throw Exception('network');
    return announcements;
  }
}

class _NotificationsOnly extends Mock
    implements DecentralizedBackendAdapter, NotificationSupport {
  @override
  Set<NotificationType> get filterableNotificationTypes => {
    NotificationType.mention,
  };
}

class _OneAccount extends AccountManagerNotifier {
  _OneAccount(this.account);

  final Account account;

  @override
  AccountManagerState build() =>
      AccountManagerState(accounts: [account], current: account);
}

Account _account(DecentralizedBackendAdapter adapter) => Account(
  key: const AccountKey(
    type: BackendType.mastodon,
    host: 'example.test',
    username: 'me',
  ),
  adapter: adapter,
  user: const User(id: 'me', username: 'me'),
  userSecret: const UserSecret(accessToken: 'token'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    initSharedPreferencesCache(await SharedPreferences.getInstance());
  });

  group('mergeAnnouncements', () {
    final notifications = [
      _mention('3', _at(12)),
      _mention('2', _at(10)),
      _mention('1', _at(8)),
    ];

    test('公開日時の位置に入り、通知の並びは動かさない', () {
      final result = mergeAnnouncements(notifications, [
        _announcement('a', _at(11)),
        _announcement('b', _at(13)),
      ], hasMore: true);

      expect(result.merged.map((n) => n.id), [
        'announcement:b',
        '3',
        'announcement:a',
        '2',
        '1',
      ]);
      expect(result.pending, isEmpty);
    });

    test('⚠⚠ 続きがあるうちは、並んでいる通知より古いお知らせを持ち越す', () {
      final result = mergeAnnouncements(notifications, [
        _announcement('old', _at(7)),
      ], hasMore: true);

      expect(result.merged.map((n) => n.id), ['3', '2', '1']);
      expect(result.pending.map((a) => a.id), ['old']);
    });

    test('続きが無ければ、古いお知らせも末尾に入れる', () {
      final result = mergeAnnouncements(notifications, [
        _announcement('old', _at(7)),
      ], hasMore: false);

      expect(result.merged.map((n) => n.id).last, 'announcement:old');
      expect(result.pending, isEmpty);
    });

    test('同じ時刻なら通知の後ろ', () {
      final result = mergeAnnouncements(notifications, [
        _announcement('same', _at(10)),
      ], hasMore: true);

      expect(result.merged.map((n) => n.id), [
        '3',
        '2',
        'announcement:same',
        '1',
      ]);
    });

    test('⚠ 通知が 1 件も無く続きがあるときは、差し込まずに持ち越す', () {
      final result = mergeAnnouncements(const [], [
        _announcement('a', _at(9)),
      ], hasMore: true);

      expect(result.merged, isEmpty);
      expect(result.pending.map((a) => a.id), ['a']);
    });

    test('お知らせの行は既読の印をお知らせの既読から取る', () {
      final row = mergeAnnouncements(notifications, [
        _announcement('a', _at(11), read: true),
      ], hasMore: true).merged[1];

      expect(isAnnouncementRow(row), isTrue);
      expect(row.unread, isFalse);
      expect(row.type, NotificationType.announcement);
    });
  });

  group('firstServerNotificationIndex（既読位置・カーソル）', () {
    final rows = [
      announcementAsNotification(_announcement('a', _at(13))),
      _mention('3', _at(12)),
      announcementAsNotification(_announcement('b', _at(11))),
    ];

    test('⚠⚠ お知らせの行を飛ばして、その下の通知の位置を返す', () {
      expect(firstServerNotificationIndex(rows), 1);
      expect(firstServerNotificationIndex(rows, 1), 1);
    });

    test('下に通知が無ければ null', () {
      expect(firstServerNotificationIndex(rows, 2), isNull);
    });
  });

  // v2.7 のリリース PR の Codex P2: お知らせが画面の上を占めているとき、
  // 画面の外の通知を既読の起点にしない。
  group('topVisibleServerNotificationIndex（見えている行だけを既読の起点にする）', () {
    final rows = [
      announcementAsNotification(_announcement('a', _at(14))),
      announcementAsNotification(_announcement('b', _at(13))),
      _mention('3', _at(12)),
      _mention('2', _at(11)),
    ];

    test('⚠⚠ 見えているのがお知らせの行だけなら null（画面の外の通知を拾わない）', () {
      expect(topVisibleServerNotificationIndex(rows, [0, 1]), isNull);
    });

    test('見えている通知の行のうち、一番上を返す', () {
      expect(topVisibleServerNotificationIndex(rows, [3, 1, 2]), 2);
    });

    test('一覧の外の位置（末尾の入口など）は無視する', () {
      expect(topVisibleServerNotificationIndex(rows, [3, 4, 5]), 3);
      expect(topVisibleServerNotificationIndex(rows, [4]), isNull);
    });
  });

  group('お知らせの行の id', () {
    final rows = [
      announcementAsNotification(_announcement('a', _at(13))),
      _mention('3', _at(12)),
      announcementAsNotification(_announcement('b', _at(11))),
    ];

    test('⚠ ストリーミングの経路と同じ id を持つ（重ならない）が、サーバーの通知とは見分ける', () {
      expect(rows.first.id, 'announcement:a');
      expect(isAnnouncementRow(_mention('announcement:x', _at(1))), isFalse);
    });
  });

  group('Announcement.edited', () {
    test('更新時刻が無ければ編集されていない', () {
      expect(_announcement('a', _at(1)).edited, isFalse);
    });

    test('⚠ 1 分までの差は編集と見なさない（Mastodon は作成時にも入れる）', () {
      expect(
        _announcement(
          'a',
          _at(1),
          updatedAt: _at(1).add(const Duration(seconds: 30)),
        ).edited,
        isFalse,
      );
    });

    test('公開のあとに編集されていれば true', () {
      expect(_announcement('a', _at(1), updatedAt: _at(2)).edited, isTrue);
    });
  });

  group('notificationDetailText（お知らせ）', () {
    String? detail(Announcement a) =>
        notificationDetailText(announcementAsNotification(a));

    test('題名があれば題名', () {
      expect(detail(_announcement('a', _at(1), title: 'メンテナンス')), 'メンテナンス');
    });

    test('題名が無ければ本文の冒頭の 1 行（HTML はタグを落とす）', () {
      expect(
        detail(
          _announcement(
            'a',
            _at(1),
            content: '<p>今夜 <b>停止</b> します</p><p>詳細は…</p>',
            isHtml: true,
          ),
        ),
        '今夜 停止 します',
      );
    });

    test('編集されていれば印を付ける', () {
      expect(
        detail(_announcement('a', _at(1), title: '告知', updatedAt: _at(3))),
        '告知（編集済み）',
      );
    });
  });

  group('通知の種類の絞り込み', () {
    List<NotificationType> filterableFor(DecentralizedBackendAdapter adapter) {
      final account = _account(adapter);
      final container = ProviderContainer(
        overrides: [
          accountManagerProvider.overrideWith(() => _OneAccount(account)),
        ],
      );
      addTearDown(container.dispose);
      return container.read(notificationFilterableTypesProvider);
    }

    test('お知らせを読めるアカウントがあれば「お知らせ」を候補に出す', () {
      expect(
        filterableFor(_Adapter(const [], const [])),
        contains(NotificationType.announcement),
      );
    });

    test('⚠ 読めなければ出さない', () {
      expect(
        filterableFor(_NotificationsOnly()),
        isNot(contains(NotificationType.announcement)),
      );
    });
  });

  group('includeAnnouncementsInNotifications', () {
    tearDown(
      () =>
          AnnouncementSubscriptionService.debugPlatformSupportedOverride = null,
    );

    test('⚠⚠ トグルが無いところ（お知らせのプッシュに対応していない）では、OFF の印があっても含める', () async {
      AnnouncementSubscriptionService.debugPlatformSupportedOverride = true;
      SharedPreferences.setMockInitialValues({
        '${AnnouncementSubscriptionService.prefsKeyOptOutPrefix}'
                'mastodon://me@example.test':
            true,
      });
      final account = _account(_Adapter(const [], const []));

      expect(await includeAnnouncementsInNotifications(account), isTrue);
    });

    test('⚠ Linux（トグルが無い）でも含める', () async {
      AnnouncementSubscriptionService.debugPlatformSupportedOverride = false;
      final account = _account(_Adapter(const [], const []));

      expect(await includeAnnouncementsInNotifications(account), isTrue);
    });
  });

  group('通知の provider', () {
    /// [before] は読み込みを始める前に済ませておく設定（絞り込みなど）。
    Future<ProviderContainer> containerFor(
      _Adapter adapter, {
      Future<void> Function(ProviderContainer container)? before,
    }) async {
      final container = ProviderContainer(
        overrides: [
          currentAccountProvider.overrideWith((ref) => _account(adapter)),
        ],
      );
      addTearDown(container.dispose);
      await before?.call(container);
      container.listen(notificationProvider, (_, _) {}, fireImmediately: true);
      return container;
    }

    // 25 件（1 ページ 20 件）。新しい順に 1 時間ずつ。
    final all = [
      for (var n = 25; n >= 1; n--)
        _mention('$n', DateTime.utc(2026, 10, 1).add(Duration(hours: n))),
    ];
    final newer = _announcement(
      'new',
      DateTime.utc(2026, 10, 1).add(const Duration(hours: 24, minutes: 30)),
    );
    final older = _announcement(
      'old',
      DateTime.utc(2026, 10, 1).add(const Duration(hours: 2, minutes: 30)),
    );

    test('最初の読み込みで範囲に入るお知らせを差し込み、古いものは持ち越す', () async {
      final container = await containerFor(_Adapter(all, [newer, older]));

      final state = await container.read(notificationProvider.future);

      expect(state.notifications.map((n) => n.id).take(3), [
        '25',
        'announcement:new',
        '24',
      ]);
      expect(state.pendingAnnouncements.map((a) => a.id), ['old']);
      expect(state.rawNewestId, '25', reason: '既読位置はサーバーの通知');
    });

    test('追加読み込みで範囲に入ったお知らせを差し込む', () async {
      final adapter = _Adapter(all, [newer, older]);
      final container = await containerFor(adapter);
      await container.read(notificationProvider.future);

      await container.read(notificationProvider.notifier).loadMore();
      final state = container.read(notificationProvider).requireValue;

      final ids = state.notifications.map((n) => n.id).toList();
      expect(ids.indexOf('announcement:old'), ids.indexOf('3') + 1);
      expect(state.pendingAnnouncements, isEmpty);
      expect(adapter.requestedMaxIds, [null, '6'], reason: 'カーソルはサーバーの通知');
    });

    test('⚠ 絞り込みで「お知らせ」を外すと並べない', () async {
      final container = await containerFor(
        _Adapter(all, [newer, older]),
        before: (c) => c
            .read(notificationExcludedTypesProvider.notifier)
            .setExcluded(NotificationType.announcement, true),
      );

      final state = await container.read(notificationProvider.future);

      expect(state.notifications.where(isAnnouncementRow), isEmpty);
      expect(state.pendingAnnouncements, isEmpty);
    });

    test('⚠⚠ お知らせが取れなくても、通知の一覧は出る', () async {
      final adapter = _Adapter(all, [newer])..failAnnouncements = true;
      final container = await containerFor(adapter);

      final state = await container.read(notificationProvider.future);

      expect(state.notifications, hasLength(20));
      expect(state.notifications.where(isAnnouncementRow), isEmpty);
    });
  });
}

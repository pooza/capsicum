import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
// capsicum_core の `Page` (Misskey ページ) と Flutter の `Page` (Navigator)
// が衝突するため Flutter 側を hide する。ルーター本体は GoRoute / GoRouter
// のみ使うため Flutter Page は不要。
import 'package:flutter/widgets.dart' hide Page;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'provider/account_manager_provider.dart';
import 'ui/screen/achievement_screen.dart';
import 'ui/screen/annict_record_screen.dart';
import 'ui/screen/annict_review_screen.dart';
import 'ui/screen/announcement_screen.dart';
import 'ui/screen/antenna_notes_screen.dart';
import 'ui/screen/bookmark_screen.dart';
import 'ui/screen/channel_timeline_screen.dart';
import 'ui/screen/chat_invitations_screen.dart';
import 'ui/screen/chat_new_thread_screen.dart';
import 'ui/screen/chat_room_edit_screen.dart';
import 'ui/screen/chat_room_invite_screen.dart';
import 'ui/screen/chat_room_members_screen.dart';
import 'ui/screen/chat_room_timeline_screen.dart';
import 'ui/screen/chat_thread_list_screen.dart';
import 'ui/screen/chat_thread_screen.dart';
import 'ui/screen/clip_notes_screen.dart';
import 'ui/screen/collection_detail_screen.dart';
import 'ui/screen/collections_list_screen.dart';
import 'ui/screen/compose_screen.dart';
import 'ui/screen/drafts_screen.dart';
import 'ui/screen/drive_manager_screen.dart';
import 'ui/screen/episode_browser_screen.dart';
import 'ui/screen/eula_screen.dart';
import 'ui/screen/flash_view_screen.dart';
import 'ui/screen/gallery_detail_screen.dart';
import 'ui/screen/gallery_screen.dart';
import 'ui/screen/hashtag_timeline_screen.dart';
import 'ui/screen/home_screen.dart';
import 'ui/screen/list_management_screen.dart';
import 'ui/screen/list_members_screen.dart';
import 'ui/screen/list_timeline_screen.dart';
import 'ui/screen/login_screen.dart';
import 'ui/screen/media_catalog_screen.dart';
import 'ui/screen/media_viewer_screen.dart';
import 'ui/screen/moderation_list_screen.dart';
import 'ui/screen/notification_screen.dart';
import 'ui/screen/page_view_screen.dart';
import 'ui/screen/pages_screen.dart';
import 'ui/screen/post_detail_screen.dart';
import 'ui/screen/profile_edit_screen.dart';
import 'ui/screen/profile_screen.dart';
import 'ui/screen/scheduled_posts_screen.dart';
import 'ui/screen/search_screen.dart';
import 'ui/screen/server_info_screen.dart';
import 'ui/screen/server_selection_screen.dart';
import 'ui/screen/settings/account_settings_screen.dart';
import 'ui/screen/settings/appearance_settings_screen.dart';
import 'ui/screen/settings/desktop_settings_screen.dart';
import 'ui/screen/settings/display_settings_screen.dart';
import 'ui/screen/settings/push_notification_settings_screen.dart';
import 'ui/screen/settings/settings_backup_screen.dart';
import 'ui/screen/settings/supporter_screen.dart';
import 'ui/screen/settings/touch_action_settings_screen.dart';
import 'ui/screen/settings_screen.dart';
import 'ui/screen/splash_screen.dart';
import 'ui/screen/templates_manage_screen.dart';
import 'ui/screen/unified_notification_screen.dart';
import 'ui/screen/user_list_screen.dart';
import 'ui/widget/desktop_menu_bar.dart';

/// Navigator key exposed for navigation from notification taps.
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// 認証後ルートを包む ShellRoute 用の Navigator key (#834)。
final shellNavigatorKey = GlobalKey<NavigatorState>();

/// A [ChangeNotifier] that notifies GoRouter when auth state changes.
class _AuthNotifier extends ChangeNotifier {
  bool _isLoggedIn = false;

  bool get isLoggedIn => _isLoggedIn;

  set isLoggedIn(bool value) {
    if (_isLoggedIn != value) {
      _isLoggedIn = value;
      notifyListeners();
    }
  }
}

final _authNotifierProvider = Provider<_AuthNotifier>((ref) {
  final notifier = _AuthNotifier();

  ref.listen(accountManagerProvider, (prev, next) {
    // オフライン保持中のアカウントも「ログイン済み」に含める (#917)。含めないと、
    // 完全オフライン起動で全アカウントの probe が失敗したときに `current` が
    // null のままになり、splash が `/home` へ送った直後に下の redirect が
    // `/server`（サーバー選択画面）へ引き戻して、ログアウトしたように見える。
    // `/home` へ通れば HomeScreen が「接続できません／再試行」を出す (#792)。
    notifier.isLoggedIn = next.hasSession;
  });

  return notifier;
});

final routerProvider = Provider<GoRouter>((ref) {
  final authNotifier = ref.read(_authNotifierProvider);

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/splash',
    refreshListenable: authNotifier,
    redirect: (context, state) {
      final isLoggedIn = authNotifier.isLoggedIn;
      final location = state.matchedLocation;
      final isOnAuth =
          location == '/login' ||
          location == '/server' ||
          location == '/splash' ||
          location == '/eula';

      if (!isLoggedIn && !isOnAuth) return '/server';
      return null;
    },
    routes: [
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: '/server',
        // `?host=` は未接続アカウントの「接続し直す」導線 (#967)。無ければ
        // 従来どおり空欄で開く。`matchedLocation` はクエリを含まないので、
        // 上の `isOnAuth` 判定はそのまま効く。
        builder: (context, state) => ServerSelectionScreen(
          initialHost: state.uri.queryParameters['host'],
        ),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) {
          // rebuild 中に extra が失われるケース（Sentry CAPSICUM-16）に備え、
          // 強制 unwrap せず null の場合はサーバー選択へ戻す。
          final extra = state.extra as Map<String, dynamic>?;
          if (extra == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) context.go('/server');
            });
            return const SizedBox.shrink();
          }
          return LoginScreen(
            host: extra['host'] as String,
            backendType: extra['backendType'] as BackendType,
            softwareVersion: extra['softwareVersion'] as String?,
          );
        },
      ),
      GoRoute(
        path: '/eula',
        builder: (context, state) {
          final nextRoute = state.extra as String? ?? '/server';
          return EulaScreen(nextRoute: nextRoute);
        },
      ),
      // メディアビューアは没入フルスクリーン + 独自キーボード操作のため shell の
      // 外（root navigator 側）に置き、デスクトップメニューバーを出さない (#834)。
      GoRoute(
        path: '/media',
        builder: (context, state) {
          final extra = state.extra! as Map<String, dynamic>;
          return MediaViewerScreen(
            attachments: extra['attachments'] as List<Attachment>,
            initialIndex: extra['initialIndex'] as int? ?? 0,
            postAuthorId: extra['postAuthorId'] as String?,
            postId: extra['postId'] as String?,
          );
        },
      ),
      // 認証後の全ルートを ShellRoute で包み、デスクトップメニューバー
      // ([DesktopMenuBar]) を常駐させる (#834)。/settings や /compose 等へ push
      // してもメニューが保持される。/media だけは没入のため上の root 側に残す。
      ShellRoute(
        navigatorKey: shellNavigatorKey,
        builder: (context, state, child) => DesktopMenuBar(child: child),
        routes: [
          GoRoute(
            path: '/home',
            builder: (context, state) => const HomeScreen(),
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            path: '/settings/account',
            builder: (context, state) => const AccountSettingsScreen(),
          ),
          GoRoute(
            path: '/settings/appearance',
            builder: (context, state) => const AppearanceSettingsScreen(),
          ),
          GoRoute(
            path: '/settings/display',
            builder: (context, state) => const DisplaySettingsScreen(),
          ),
          GoRoute(
            path: '/settings/touch',
            builder: (context, state) => const TouchActionSettingsScreen(),
          ),
          // ブロック / ミュートの一覧と解除 (#1039)。設定の下だが中身は管理 UI
          // なので独立画面（#805 の様式）。
          GoRoute(
            path: '/settings/moderation',
            builder: (context, state) => const ModerationListScreen(),
          ),
          GoRoute(
            path: '/settings/desktop',
            builder: (context, state) => const DesktopSettingsScreen(),
          ),
          GoRoute(
            path: '/settings/push',
            builder: (context, state) => const PushNotificationSettingsScreen(),
          ),
          GoRoute(
            path: '/settings/supporter',
            builder: (context, state) => const SupporterScreen(),
          ),
          GoRoute(
            path: '/settings/backup',
            builder: (context, state) => const SettingsBackupScreen(),
          ),
          GoRoute(
            path: '/server-info',
            builder: (context, state) => const ServerInfoScreen(),
          ),
          GoRoute(
            path: '/lists/manage',
            builder: (context, state) => const ListManagementScreen(),
          ),
          GoRoute(
            path: '/lists/members',
            builder: (context, state) {
              final postList = state.extra! as PostList;
              return ListMembersScreen(postList: postList);
            },
          ),
          GoRoute(
            path: '/compose',
            builder: (context, state) {
              final extra = state.extra as Map<String, dynamic>?;
              final restoreDraft = extra?['restoreDraft'] as Draft?;
              // 下書き復元では、埋め込みの reply / renote / channel を compose の
              // widget パラメータへ流し、リプライ/引用/チャンネル文脈を再構築する
              // (#833)。compose 側は _effectiveChannelId / _quotedPost / 送信経路が
              // これらの widget フィールドを既に参照するため本体は無改修。明示 extra
              // （通常のリプライ/引用起動）があればそちらを優先する。
              return ComposeScreen(
                redraft: extra?['redraft'] as Post?,
                replyTo: extra?['replyTo'] as Post? ?? restoreDraft?.reply,
                quoteTo: extra?['quoteTo'] as Post? ?? restoreDraft?.renote,
                channelId:
                    extra?['channelId'] as String? ?? restoreDraft?.channelId,
                channelName:
                    extra?['channelName'] as String? ??
                    restoreDraft?.channelName,
                sharedText: extra?['sharedText'] as String?,
                initialText: extra?['initialText'] as String?,
                restoreDraft: restoreDraft,
                template: extra?['template'] as ComposeTemplate?,
              );
            },
          ),
          GoRoute(
            path: '/play',
            builder: (context, state) {
              final extra = state.extra as Map<String, dynamic>?;
              return FlashViewScreen(
                initialFlash: extra?['flash'] as Flash?,
                flashId: extra?['flashId'] as String?,
              );
            },
          ),
          GoRoute(
            path: '/scheduled',
            builder: (context, state) => const ScheduledPostsScreen(),
          ),
          GoRoute(
            path: '/drafts',
            builder: (context, state) => const DraftsScreen(),
          ),
          GoRoute(
            path: '/templates/manage',
            builder: (context, state) => const TemplatesManageScreen(),
          ),
          GoRoute(
            path: '/search',
            builder: (context, state) => const SearchScreen(),
          ),
          GoRoute(
            path: '/notifications',
            builder: (context, state) => const NotificationScreen(),
          ),
          GoRoute(
            path: '/notifications/all',
            builder: (context, state) => const UnifiedNotificationScreen(),
          ),
          GoRoute(
            path: '/bookmarks',
            builder: (context, state) => const BookmarkScreen(),
          ),
          GoRoute(
            path: '/achievements',
            builder: (context, state) {
              final extra = state.extra! as Map<String, dynamic>;
              return AchievementScreen(
                userId: extra['userId'] as String,
                displayName: extra['displayName'] as String?,
              );
            },
          ),
          GoRoute(
            path: '/announcements',
            builder: (context, state) => const AnnouncementScreen(),
          ),
          GoRoute(
            path: '/post',
            builder: (context, state) {
              final post = state.extra! as Post;
              return PostDetailScreen(post: post);
            },
          ),
          GoRoute(
            path: '/profile',
            builder: (context, state) {
              final user = state.extra! as User;
              return ProfileScreen(user: user);
            },
          ),
          GoRoute(
            path: '/profile/edit',
            builder: (context, state) => const ProfileEditScreen(),
          ),
          GoRoute(
            path: '/users',
            builder: (context, state) {
              final extra = state.extra! as Map<String, dynamic>;
              return UserListScreen(
                title: extra['title'] as String,
                fetcher: extra['fetcher'] as UserListFetcher,
              );
            },
          ),
          GoRoute(
            path: '/collections',
            builder: (context, state) {
              final extra = state.extra! as Map<String, dynamic>;
              return CollectionsListScreen(
                accountId: extra['accountId'] as String,
                inCollections: extra['inCollections'] as bool? ?? false,
                ownerView: extra['ownerView'] as bool? ?? false,
                title: extra['title'] as String,
              );
            },
          ),
          GoRoute(
            path: '/collection',
            builder: (context, state) =>
                CollectionDetailScreen(collectionId: state.extra! as String),
          ),
          GoRoute(
            path: '/hashtag/:tag',
            builder: (context, state) {
              final tag = state.pathParameters['tag']!;
              return HashtagTimelineScreen(hashtag: tag);
            },
          ),
          GoRoute(
            path: '/channel/:id',
            builder: (context, state) {
              final id = state.pathParameters['id']!;
              final name = state.extra as String?;
              return ChannelTimelineScreen(channelId: id, channelName: name);
            },
          ),
          GoRoute(
            path: '/clip/:id',
            builder: (context, state) {
              final id = state.pathParameters['id']!;
              final name = state.extra as String?;
              return ClipNotesScreen(clipId: id, clipName: name);
            },
          ),
          GoRoute(
            path: '/antenna/:id',
            builder: (context, state) {
              final id = state.pathParameters['id']!;
              final name = state.extra as String?;
              return AntennaNotesScreen(antennaId: id, antennaName: name);
            },
          ),
          GoRoute(
            path: '/list/:id',
            builder: (context, state) {
              final id = state.pathParameters['id']!;
              final name = state.extra as String?;
              return ListTimelineScreen(listId: id, listName: name);
            },
          ),
          GoRoute(
            path: '/drive',
            builder: (_, _) => const DriveManagerScreen(),
          ),
          GoRoute(
            path: '/chat',
            builder: (context, state) => const ChatThreadListScreen(),
          ),
          GoRoute(
            path: '/chat/new',
            builder: (context, state) => const ChatNewThreadScreen(),
          ),
          GoRoute(
            path: '/chat/user/:userId',
            builder: (context, state) {
              // rebuild 中に extra が失われたり、push 通知タップ等で `extra` 無しで
              // 飛んでくるケース (CAPSICUM-16 と同型、#443) に備え、強制 unwrap せず
              // null の場合はメッセージ一覧へ戻す。userId からの User 復元は
              // #440 の push 通知タップ動線整備で扱う。
              final user = state.extra as User?;
              if (user == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (context.mounted) context.go('/chat');
                });
                return const SizedBox.shrink();
              }
              return ChatThreadScreen(otherUser: user);
            },
          ),
          GoRoute(
            path: '/chat/invitations',
            builder: (context, state) => const ChatInvitationsScreen(),
          ),
          GoRoute(
            // ':roomId' より先に登録しないと "new" が roomId として吸われる。
            path: '/chat/room/new',
            builder: (context, state) => const ChatRoomEditScreen(),
          ),
          GoRoute(
            path: '/chat/room/:roomId/edit',
            builder: (context, state) {
              final room = state.extra as ChatRoom?;
              if (room == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (context.mounted) context.go('/chat');
                });
                return const SizedBox.shrink();
              }
              return ChatRoomEditScreen(initialRoom: room);
            },
          ),
          GoRoute(
            path: '/chat/room/:roomId/members',
            builder: (context, state) {
              final room = state.extra as ChatRoom?;
              if (room == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (context.mounted) context.go('/chat');
                });
                return const SizedBox.shrink();
              }
              return ChatRoomMembersScreen(room: room);
            },
          ),
          GoRoute(
            path: '/chat/room/:roomId/invite',
            builder: (context, state) {
              final room = state.extra as ChatRoom?;
              if (room == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (context.mounted) context.go('/chat');
                });
                return const SizedBox.shrink();
              }
              return ChatRoomInviteScreen(room: room);
            },
          ),
          GoRoute(
            path: '/chat/room/:roomId',
            builder: (context, state) {
              // /chat/user/:userId と同じく rebuild / push 通知由来で extra が
              // 失われるケースに備え、null なら一覧へ戻す。roomId からの ChatRoom
              // 復元 (/chat/rooms/show 直叩き) は Phase E で push 通知タップ動線を
              // 整える際に扱う (#438)。
              final room = state.extra as ChatRoom?;
              if (room == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (context.mounted) context.go('/chat');
                });
                return const SizedBox.shrink();
              }
              return ChatRoomTimelineScreen(room: room);
            },
          ),
          GoRoute(
            path: '/gallery',
            builder: (context, state) => const GalleryScreen(),
          ),
          GoRoute(
            path: '/gallery/:id',
            builder: (context, state) {
              final post = state.extra as GalleryPost;
              return GalleryDetailScreen(post: post);
            },
          ),
          // Misskey ページのハブ画面 (#186)。drawer から開く。v1 では
          // 「いいねしたページ」のみ表示するが、将来 WebUI の『人気』『自分のページ』
          // を同画面に追加する想定で `/pages` 単一ルートに集約する。
          GoRoute(
            path: '/pages',
            builder: (context, state) => const PagesScreen(),
          ),
          // Misskey ページ (#186) by-id 直接遷移。push 通知や future deeplink で
          // 使う想定。state.extra に Page を渡せばその場で表示し、無ければ
          // pageId から adapter 経由で fetch する。
          GoRoute(
            path: '/page/:id',
            builder: (context, state) {
              final id = state.pathParameters['id']!;
              final page = state.extra as Page?;
              return PageViewScreen(
                initialPage: page,
                pageId: page == null ? id : null,
              );
            },
          ),
          // Misskey の正規 URL `https://host/@username/pages/<name>` 形式を
          // そのまま path として扱うルート。in-app から context.push する経路と、
          // 将来の OS 経由 deeplink の双方で使う。
          GoRoute(
            path: '/@:username/pages/:name',
            builder: (context, state) {
              final username = state.pathParameters['username']!;
              final name = state.pathParameters['name']!;
              return PageViewScreen(username: username, name: name);
            },
          ),
          GoRoute(
            path: '/episodes',
            builder: (context, state) => const EpisodeBrowserScreen(),
          ),
          GoRoute(
            path: '/annict/record',
            builder: (context, state) {
              final args = state.extra! as AnnictRecordScreenArgs;
              return AnnictRecordScreen(args: args);
            },
          ),
          GoRoute(
            path: '/annict/review',
            builder: (context, state) {
              final args = state.extra! as AnnictReviewScreenArgs;
              return AnnictReviewScreen(args: args);
            },
          ),
          GoRoute(
            path: '/media-catalog',
            builder: (context, state) => const MediaCatalogScreen(),
          ),
        ],
      ),
    ],
  );
});

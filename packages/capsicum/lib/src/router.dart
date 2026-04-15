import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'provider/account_manager_provider.dart';
import 'ui/screen/achievement_screen.dart';
import 'ui/screen/announcement_screen.dart';
import 'ui/screen/antenna_notes_screen.dart';
import 'ui/screen/drive_manager_screen.dart';
import 'ui/screen/bookmark_screen.dart';
import 'ui/screen/compose_screen.dart';
import 'ui/screen/media_viewer_screen.dart';
import 'ui/screen/channel_timeline_screen.dart';
import 'ui/screen/clip_notes_screen.dart';
import 'ui/screen/eula_screen.dart';
import 'ui/screen/gallery_detail_screen.dart';
import 'ui/screen/gallery_screen.dart';
import 'ui/screen/hashtag_timeline_screen.dart';
import 'ui/screen/home_screen.dart';
import 'ui/screen/login_screen.dart';
import 'ui/screen/notification_screen.dart';
import 'ui/screen/unified_notification_screen.dart';
import 'ui/screen/post_detail_screen.dart';
import 'ui/screen/profile_edit_screen.dart';
import 'ui/screen/profile_screen.dart';
import 'ui/screen/search_screen.dart';
import 'ui/screen/server_selection_screen.dart';
import 'ui/screen/server_info_screen.dart';
import 'ui/screen/settings_screen.dart';
import 'ui/screen/settings/account_settings_screen.dart';
import 'ui/screen/settings/appearance_settings_screen.dart';
import 'ui/screen/settings/display_settings_screen.dart';
import 'ui/screen/settings/notification_diagnostics_screen.dart';
import 'ui/screen/episode_browser_screen.dart';
import 'ui/screen/media_catalog_screen.dart';
import 'ui/screen/list_management_screen.dart';
import 'ui/screen/list_members_screen.dart';
import 'ui/screen/scheduled_posts_screen.dart';
import 'ui/screen/splash_screen.dart';
import 'ui/screen/user_list_screen.dart';

/// Navigator key exposed for navigation from notification taps.
final rootNavigatorKey = GlobalKey<NavigatorState>();

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
    notifier.isLoggedIn = next.current != null;
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
        builder: (context, state) => const ServerSelectionScreen(),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) {
          final extra = state.extra! as Map<String, dynamic>;
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
      GoRoute(path: '/home', builder: (context, state) => const HomeScreen()),
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
        path: '/settings/notification-diagnostics',
        builder: (context, state) => const NotificationDiagnosticsScreen(),
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
          return ComposeScreen(
            redraft: extra?['redraft'] as Post?,
            replyTo: extra?['replyTo'] as Post?,
            quoteTo: extra?['quoteTo'] as Post?,
            channelId: extra?['channelId'] as String?,
            channelName: extra?['channelName'] as String?,
            sharedText: extra?['sharedText'] as String?,
            initialText: extra?['initialText'] as String?,
          );
        },
      ),
      GoRoute(
        path: '/scheduled',
        builder: (context, state) => const ScheduledPostsScreen(),
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
      GoRoute(path: '/drive', builder: (_, _) => const DriveManagerScreen()),
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
      GoRoute(
        path: '/episodes',
        builder: (context, state) => const EpisodeBrowserScreen(),
      ),
      GoRoute(
        path: '/media-catalog',
        builder: (context, state) => const MediaCatalogScreen(),
      ),
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
    ],
  );
});

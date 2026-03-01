import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'provider/account_manager_provider.dart';
import 'ui/screen/home_screen.dart';
import 'ui/screen/login_screen.dart';
import 'ui/screen/server_selection_screen.dart';
import 'ui/screen/compose_screen.dart';
import 'ui/screen/post_detail_screen.dart';
import 'ui/screen/splash_screen.dart';

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
    initialLocation: '/splash',
    refreshListenable: authNotifier,
    redirect: (context, state) {
      final isLoggedIn = authNotifier.isLoggedIn;
      final location = state.matchedLocation;
      final isOnAuth =
          location == '/login' ||
          location == '/server' ||
          location == '/splash';

      if (!isLoggedIn && !isOnAuth) return '/server';
      if (isLoggedIn && location == '/splash') return '/home';
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
          );
        },
      ),
      GoRoute(
        path: '/home',
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: '/compose',
        builder: (context, state) => const ComposeScreen(),
      ),
      GoRoute(
        path: '/post',
        builder: (context, state) {
          final post = state.extra! as Post;
          return PostDetailScreen(post: post);
        },
      ),
    ],
  );
});

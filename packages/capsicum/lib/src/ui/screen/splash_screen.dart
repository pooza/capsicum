import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../main.dart' show firebaseReady, pendingSharedText, shareIntentReady;
import '../../provider/account_manager_provider.dart';
import '../../service/push_registration_service.dart';
import 'eula_screen.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _restoreSessions();
  }

  Future<void> _restoreSessions() async {
    var skippedAccounts = 0;
    try {
      skippedAccounts = await ref
          .read(accountManagerProvider.notifier)
          .restoreSessions();
    } catch (e, st) {
      debugPrint('capsicum: failed to restore sessions: $e\n$st');
    }
    if (!mounted) return;

    // Firebase 初期化を待ってからプッシュ通知登録（ベストエフォート）。
    // 起動時点のアカウント一覧をクロージャーで固定すると、Firebase 初期化中
    // にユーザーがログアウトしたアカウントまで再登録してしまうため、登録
    // 実行時に最新状態を ProviderContainer 経由で再取得する。
    if (ref.read(accountManagerProvider).accounts.isNotEmpty) {
      final container = ProviderScope.containerOf(context, listen: false);
      firebaseReady.then((_) {
        final latest = container.read(accountManagerProvider).accounts;
        if (latest.isNotEmpty) {
          PushRegistrationService.registerAllAccounts(latest);
        }
      });
    }

    if (skippedAccounts > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('セキュリティキーの変更により$skippedAccounts件のアカウントで再ログインが必要です'),
            duration: const Duration(seconds: 5),
          ),
        );
      });
    }

    final prefs = await SharedPreferences.getInstance();
    final eulaAccepted = prefs.getBool(eulaAcceptedKey) ?? false;
    if (!mounted) return;

    // Wait for the share intent check to complete before deciding the route.
    await shareIntentReady;
    if (!mounted) return;

    final hasAccount = ref.read(accountManagerProvider).current != null;

    // If a share intent is pending and the user is logged in, go to compose.
    final shared = pendingSharedText;
    if (shared != null && hasAccount) {
      pendingSharedText = null;
      final nextRoute = '/compose';
      final extra = <String, dynamic>{'sharedText': shared};
      if (!eulaAccepted) {
        // EULA must be accepted first; shared text is lost in this edge case.
        context.go('/eula', extra: '/home');
      } else {
        context.go(nextRoute, extra: extra);
      }
      return;
    }

    final nextRoute = hasAccount ? '/home' : '/server';
    if (!eulaAccepted) {
      context.go('/eula', extra: nextRoute);
    } else {
      context.go(nextRoute);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/images/logo.png', height: 64),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

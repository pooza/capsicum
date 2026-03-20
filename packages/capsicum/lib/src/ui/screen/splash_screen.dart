import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../provider/account_manager_provider.dart';
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
    await ref.read(accountManagerProvider.notifier).restoreSessions();
    if (!mounted) return;

    final prefs = await SharedPreferences.getInstance();
    final eulaAccepted = prefs.getBool(eulaAcceptedKey) ?? false;
    if (!mounted) return;

    final hasAccount = ref.read(accountManagerProvider).current != null;
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

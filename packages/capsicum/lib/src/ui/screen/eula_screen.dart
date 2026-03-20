import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../constants.dart';

/// Key used to persist EULA acceptance state.
const eulaAcceptedKey = 'eula_accepted';

class EulaScreen extends StatelessWidget {
  /// Where to navigate after acceptance.
  final String nextRoute;

  const EulaScreen({super.key, required this.nextRoute});

  Future<void> _accept(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(eulaAcceptedKey, true);
    if (context.mounted) context.go(nextRoute);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Image.asset('assets/images/logo.png', height: 64),
              const SizedBox(height: 24),
              Text(
                AppConstants.appName,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 32),
              const Text(
                'capsicum を利用するには、利用規約への同意が必要です。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                '本アプリでは、不適切なコンテンツや迷惑行為に対して一切の寛容を持ちません。'
                '利用者は通報機能およびブロック機能を利用できます。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              TextButton(
                onPressed: () => launchUrl(AppConstants.termsUrl),
                child: const Text('利用規約を読む'),
              ),
              TextButton(
                onPressed: () => launchUrl(
                  AppConstants.websiteUrl.replace(path: '/privacy-policy'),
                ),
                child: const Text('プライバシーポリシーを読む'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => _accept(context),
                child: const Text('同意して続ける'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

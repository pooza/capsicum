import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../constants.dart';
import '../../url_helper.dart';

/// 左ドロワー「capsicum について」と macOS メニューバー「About capsicum」の
/// 両方から呼ばれる統一 About ダイアログ。
Future<void> showAboutCapsicum(BuildContext context) async {
  final info = await PackageInfo.fromPlatform();
  if (!context.mounted) return;
  showAboutDialog(
    context: context,
    applicationName: AppConstants.appName,
    applicationVersion: 'v${info.version} (${info.buildNumber})',
    applicationIcon: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.asset('assets/images/logo.png', width: 48, height: 48),
    ),
    applicationLegalese: 'Mastodon / Misskey クライアント',
    children: [
      const SizedBox(height: 16),
      _AboutLink(
        url: AppConstants.websiteUrl,
        label: AppConstants.websiteUrl.toString(),
      ),
      const SizedBox(height: 8),
      _AboutLink(url: AppConstants.communityUrl, label: 'コミュニティ（PieFed）'),
      const SizedBox(height: 8),
      _AboutLink(url: AppConstants.contactUrl, label: 'お問い合わせ'),
    ],
  );
}

class _AboutLink extends StatelessWidget {
  final Uri url;
  final String label;

  const _AboutLink({required this.url, required this.label});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => launchUrlSafely(url),
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../constants.dart';
import '../../provider/supporter_purchase_provider.dart';
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
      // 投げ銭（サポート）導線 (#853)。外部 URL ではなく /settings/supporter への
      // 内部遷移で、IAP 提供プラットフォーム限定（ドロワーと同じ
      // [supporterEntryVisibleProvider]）。非対応 OS では出さない。
      Consumer(
        builder: (context, ref, _) {
          if (!ref.watch(supporterEntryVisibleProvider)) {
            return const SizedBox.shrink();
          }
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _AboutLink(
              label: 'capsicum をサポート（投げ銭）',
              // ダイアログを閉じてから購入画面へ遷移する。context は pop 後に
              // defunct になるため router を先に掴んでおく。
              onTap: () {
                final router = GoRouter.of(context);
                Navigator.of(context).pop();
                router.push('/settings/supporter');
              },
            ),
          );
        },
      ),
    ],
  );
}

class _AboutLink extends StatelessWidget {
  final Uri? url;
  final String label;
  final VoidCallback? onTap;

  const _AboutLink({required this.label, this.url, this.onTap})
    : assert(url != null || onTap != null);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap ?? () => launchUrlSafely(url!),
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

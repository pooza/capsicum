import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../provider/preferences_provider.dart';
import '../../../url_helper.dart';
import '../../widget/bottom_safe_area.dart';

/// 本文のリンクを専用アプリで開くサービスを選ぶ画面 (#1345)。
///
/// アプリが微妙に不便なサービスは、外すとブラウザで開く。モバイルだけに出す
/// （デスクトップは専用アプリへ誘導しない）。
class PreferredAppsSettingsScreen extends ConsumerWidget {
  const PreferredAppsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final disabled = ref.watch(disabledPreferredAppsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('リンクを開くアプリ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: BottomSafeArea(
        child: ListView(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('オンのサービスのリンクは、アプリが入っていればアプリで開きます。オフにするとブラウザで開きます。'),
            ),
            for (final service in preferredAppServices)
              SwitchListTile(
                title: Text(service.label),
                value: !disabled.contains(service.id),
                onChanged: (enabled) => ref
                    .read(disabledPreferredAppsProvider.notifier)
                    .setEnabled(service.id, enabled),
              ),
          ],
        ),
      ),
    );
  }
}

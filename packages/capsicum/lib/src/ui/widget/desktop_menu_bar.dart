import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/announcement_provider.dart';
import 'desktop_menu_model.dart';
import 'home_menu.dart';
import 'screen_menu.dart';

/// 認証後の全ルートを包み、デスクトップメニューバー（macOS はネイティブ・
/// Windows/Linux はウィンドウ内 MenuBar）を常駐させる shell ウィジェット (#834)。
/// メニュー骨格は単一モデル [buildDesktopMenuModel] を正本にし、macOS は
/// [renderMacMenuBar]、Windows/Linux は [renderInWindowMenuBar] へ薄いレンダラで
/// 変換する。以前は HomeScreen.build() 内で scaffold を包んでいたため、/settings や
/// /compose 等へ push するとメニューが消えていた。ShellRoute の builder からここを
/// 使うことで、認証後の全ルートでメニューを保持する。
class DesktopMenuBar extends ConsumerWidget {
  const DesktopMenuBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // デスクトップ以外（モバイル）はメニューバー無しで素通し。
    if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      return child;
    }
    final account = ref.watch(currentAccountProvider);
    final accountState = ref.watch(accountManagerProvider);
    final unreadAnnouncements = ref.watch(unreadAnnouncementCountProvider);
    // 表示中の画面が宣言したメニュー (#835) を固定メニューへ差し込む。宣言が
    // 無ければ従来どおりの固定メニューになる。
    final model = withScreenMenu(
      buildDesktopMenuModel(
        context,
        ref,
        account,
        accountState,
        unreadAnnouncements,
      ),
      ref.watch(activeScreenMenuProvider),
    );
    if (Platform.isMacOS) return renderMacMenuBar(model, child);
    return renderInWindowMenuBar(model, child); // Windows / Linux
  }
}

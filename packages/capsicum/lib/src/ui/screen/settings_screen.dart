import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../platform/platform_info.dart';
import '../../provider/account_manager_provider.dart';
import '../../service/push_registration_service.dart';
import '../util/post_scope_display.dart';
import '../widget/bottom_safe_area.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(currentAccountProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('設定'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: BottomSafeArea(
        child: ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('アカウント設定'),
              subtitle: account != null
                  ? Text('@${account.key.username}@${account.key.host}')
                  : null,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/account'),
            ),
            ListTile(
              leading: const Icon(Icons.palette),
              title: const Text('テーマ'),
              subtitle: const Text('配色・文字サイズ'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/appearance'),
            ),
            ListTile(
              leading: const Icon(Icons.visibility),
              title: const Text('表示'),
              subtitle: const Text('タイムライン表示の設定'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/display'),
            ),
            // ブロック / ミュートの一覧と解除 (#1039)。⚠ **ミュートは相手が TL
            // から出てこなくなる操作なので、ここが無いと解除の導線が塞がる。**
            ListTile(
              leading: const Icon(Icons.block),
              title: const Text('ブロックとミュート'),
              subtitle: const Text('一覧の確認・解除'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/moderation'),
            ),
            // サーバー側の投稿の既定 (#1210・Mastodon)。投稿フォームはこれを
            // 読んで使うので、端末側に別の既定は無い。
            if (ref.watch(currentAdapterProvider) is PostingDefaultsSupport)
              ListTile(
                leading: const Icon(Icons.edit_note),
                title: const Text('投稿の既定'),
                subtitle: const Text('公開範囲・閲覧注意・言語・引用の許可'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/posting-defaults'),
              ),
            // フィルター (#1047)。⚠ **名前は SNS の本来の用語**（Mastodon は
            // 「フィルター」・2026-10-15 pooza 判断）。Misskey のワードミュートは
            // #1290 で同じ位置に出す。
            if (ref.watch(currentAdapterProvider) is FilterSupport)
              ListTile(
                leading: const Icon(Icons.filter_alt_outlined),
                title: const Text('フィルター'),
                subtitle: const Text('キーワードで投稿を伏せる'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/filters'),
              )
            else if (ref.watch(currentAdapterProvider) is WordMuteSupport)
              ListTile(
                leading: const Icon(Icons.filter_alt_outlined),
                title: const Text('ワードミュート'),
                subtitle: const Text('キーワードで投稿を伏せる'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/word-mutes'),
              ),
            // フォロー中のハッシュタグ (#1070)。⚠ **#1039 と同じ「付けられる
            // のに外す導線が塞がる」形**なので隣に置く。Misskey では一覧が
            // 常に空になる（フォローの概念が無い）ため、エントリ自体を
            // アダプターで出し分ける。
            if (!isMisskeyAdapter(ref.watch(currentAdapterProvider)))
              ListTile(
                leading: const Icon(Icons.tag),
                title: const Text('フォロー中のハッシュタグ'),
                subtitle: const Text('一覧の確認・解除'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/followed-hashtags'),
              ),
            ListTile(
              leading: const Icon(Icons.touch_app),
              title: const Text('タッチ操作'),
              subtitle: const Text('投稿のボタンをタイル上に表示する'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/touch'),
            ),
            // 専用アプリへの誘導はモバイルだけ (#755 / #1345)。
            if (!isDesktop)
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: const Text('リンクを開くアプリ'),
                subtitle: const Text('サービスごとにアプリかブラウザかを選ぶ'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/preferred-apps'),
              ),
            // デスクトップ専用設定（常駐 #752 / ログイン時起動 #751 / マウスドラッグ
            // スクロール #574 / 起動時更新確認 #641）。モバイルでは出さない。
            if (isDesktop)
              ListTile(
                leading: const Icon(Icons.desktop_windows),
                title: const Text('デスクトップ'),
                subtitle: const Text('ウィンドウ常駐・ログイン時起動など'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/desktop'),
              ),
            // プッシュ通知の経路が無いプラットフォーム（現状は Linux だけ・
            // #475）では、設定エントリも隠す。macOS (#468) と Windows (#474) は
            // 配線済み。判定は [PushRegistrationService.isPushBackendWired]。
            if (PushRegistrationService.isPushBackendWired)
              ListTile(
                leading: const Icon(Icons.notifications_outlined),
                title: const Text('プッシュ通知'),
                subtitle: const Text('アカウント別の登録状況・再試行'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/push'),
              ),
            // 設定のバックアップ (#857)。モバイルは保存ダイアログが無いため
            // デスクトップ限定にしていたが、書き出しを OS の共有シートへ渡す形に
            // して 5 OS すべてに出した (#972)。
            ListTile(
              leading: const Icon(Icons.settings_backup_restore),
              title: const Text('設定のバックアップ'),
              subtitle: const Text('設定を書き出し・読み込みする'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/backup'),
            ),
            // 投げ銭（サポート）導線は「設定」から左ドロワー直下 + デスクトップ
            // メニューへ格上げした (#853)。投げ銭は設定ではないため設定からは外す。
          ],
        ),
      ),
    );
  }
}

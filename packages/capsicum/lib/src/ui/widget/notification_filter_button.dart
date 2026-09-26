import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart' hide Notification;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/server_config_provider.dart';
import '../util/notification_type_display.dart';

/// 絞り込みの候補に出せる種別 (#1042)。
///
/// ⚠⚠ **全アカウントの和集合を出す。**絞り込みは 1 つの設定でアプリ全体に効く
/// （`notificationExcludedTypesProvider`）ので、いま開いているアカウントの
/// 候補だけを出すと、**別のアカウントで外した種別を戻す手段が無くなる**
/// （Mastodon のアカウントを見ているときに、Misskey で外した「リアクション」が
/// 一覧に出ない）。
///
/// ⚠ 並びは [NotificationType.values] の順に揃える。Set の反復順は挿入順なので、
/// アカウントを足す順でメニューの並びが変わってしまう。
final notificationFilterableTypesProvider = Provider<List<NotificationType>>((
  ref,
) {
  final supported = <NotificationType>{
    for (final account in ref.watch(accountManagerProvider).accounts)
      if (account.adapter case final NotificationSupport adapter)
        ...adapter.filterableNotificationTypes,
  };
  return [
    for (final type in NotificationType.values)
      if (supported.contains(type)) type,
  ];
}, dependencies: [accountManagerProvider]);

/// 通知の種別で絞り込む入口 (#1042)。
///
/// ⚠ **絞り込みはサーバー側で効く。**設定を変えると通知一覧が取り直しになる
/// （`notificationProvider` / `unifiedNotificationProvider` が watch している）。
/// クライアント側で捨てる実装だと「絞り込むほど 1 ページの残りが減り、もっと
/// 読むを連打させる」逆転が起きる（#993 の指摘）。
///
/// ⚠⚠ **効いていることが閉じた状態で見えるようにする。**外している種別が 1 つ
/// でもあればアイコンの形と色を変える。見えないまま効いている設定は
/// `localOnly` / #1167 で繰り返し踏んでいる失敗。
class NotificationFilterButton extends ConsumerWidget {
  const NotificationFilterButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final excluded = ref.watch(notificationExcludedTypesProvider);
    final theme = Theme.of(context);
    return IconButton(
      icon: Icon(
        excluded.isEmpty ? Icons.filter_list : Icons.filter_list_off,
        color: excluded.isEmpty ? null : theme.colorScheme.error,
      ),
      tooltip: excluded.isEmpty ? '通知の絞り込み' : '${excluded.length} 種類を非表示中',
      onPressed: () => showNotificationFilterDialog(context),
    );
  }
}

/// 種別ごとの表示 / 非表示を切り替えるダイアログ (#1042)。
///
/// ⚠ **ポップアップメニューにしない。**メニューは 1 項目選ぶと閉じるので、
/// 複数の種別を切り替えるのに開き直しが要る。ダイアログなら開いたまま続けて
/// 切り替えられ、320px のカラムでも収まる。
Future<void> showNotificationFilterDialog(BuildContext context) =>
    showDialog<void>(
      context: context,
      builder: (context) => const _NotificationFilterDialog(),
    );

class _NotificationFilterDialog extends ConsumerWidget {
  const _NotificationFilterDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final types = ref.watch(notificationFilterableTypesProvider);
    final excluded = ref.watch(notificationExcludedTypesProvider);
    final reblogLabel = ref.watch(reblogLabelProvider);
    final postLabel = ref.watch(postLabelProvider);
    return AlertDialog(
      title: const Text('通知の絞り込み'),
      // ⚠ 種別は 10 件を超えるので、ダイアログの中でスクロールさせる。
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ⚠ 「その他」は候補に出していない。サーバー側の種別名を列挙でき
              // ないので除外指定が効かせられない（`NotificationQuery` の doc）。
              // 知らない種別は絞り込み中も流れてくる、と先に書いておく。
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'チェックを外した種別はサーバー側で取得しません。'
                  'capsicum が種類を判別できない通知は絞り込みの対象外です。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              for (final type in types)
                CheckboxListTile(
                  key: ValueKey('notification-filter-${type.name}'),
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    notificationTypeDisplay(
                      type,
                      reblogLabel: reblogLabel,
                      postLabel: postLabel,
                    ).label,
                  ),
                  value: !excluded.contains(type),
                  onChanged: (shown) => ref
                      .read(notificationExcludedTypesProvider.notifier)
                      .setExcluded(type, shown != true),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: excluded.isEmpty
              ? null
              : () => ref
                    .read(notificationExcludedTypesProvider.notifier)
                    .clear(),
          child: const Text('すべて表示'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('閉じる'),
        ),
      ],
    );
  }
}

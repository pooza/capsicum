import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/preferences_provider.dart';

/// 実況（`#実況`）を隠すかの切り替え。タブ UI とデッキの AppBar で共有する
/// (#1173・`docs/deck-ui-plan.md` 決定済み事項 7-3)。
///
/// ⚠ **フィルタ自体はデッキのカラムにも既に効いている。**[hideLivecureProvider] は
/// 設定値で、本線 TL / ハッシュタグ / リスト / チャンネルの各 provider の段階で
/// 除外している。**足りなかったのは切り替えの入口だけ**で、デスクトップは
/// メニューバー（表示 > 実況を表示）から切り替えられる一方、**モバイルのデッキには
/// 入口が無かった**。
class LivecureFilterButton extends ConsumerWidget {
  const LivecureFilterButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hide = ref.watch(hideLivecureProvider);
    return IconButton(
      icon: Icon(
        hide ? Icons.mic_off : Icons.mic,
        color: hide ? Theme.of(context).colorScheme.error : null,
      ),
      tooltip: hide ? '#実況 非表示中' : '#実況 表示中',
      onPressed: () => ref.read(hideLivecureProvider.notifier).toggle(),
    );
  }
}

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'list_provider.dart';
import 'timeline_provider.dart';

/// [selectedTabProvider] から派生する「いま選ばれているリスト / ハッシュタグ」。
///
/// もとは home_screen.dart にあったが、HomeScreen が body の描画に使うのと同じ
/// 判定軸を、表示中 TL の変更ハンドル ([readVisibleTimelines]) からも共有できる
/// よう provider 層へ移した (#925)。両者が同一 provider を読むことで、
/// 「HomeScreen は本線 TL を出しているのに、変更は list TL provider へ飛ぶ」
/// といった食い違いを構造的に防ぐ。

/// 選択中タブが [ListTab] のときの、解決済みの [PostList]。
///
/// `listsProvider` 未ロード / id 不一致のときは null を返す。このとき HomeScreen は
/// 本線 TL にフォールバックして描画するので、変更ハンドル側も同じく本線扱いに
/// する（見えていない list TL provider を起こして REST を無駄打ちしない）。
final selectedListProvider = Provider<PostList?>((ref) {
  final tab = ref.watch(selectedTabProvider);
  if (tab is! ListTab) return null;
  final lists = ref.watch(listsProvider).valueOrNull ?? [];
  return lists.where((l) => l.id == tab.id).firstOrNull;
});

/// 選択中タブが [HashtagTab] のときのタグ spec。
final selectedHashtagProvider = Provider<String?>((ref) {
  final tab = ref.watch(selectedTabProvider);
  return tab is HashtagTab ? tab.tag : null;
});

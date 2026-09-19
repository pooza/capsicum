import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';
import 'channel_provider.dart';
import 'hashtag_provider.dart';
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
}, dependencies: [listsProvider]);

/// 選択中タブが [HashtagTab] のときのタグ spec。
final selectedHashtagProvider = Provider<String?>((ref) {
  final tab = ref.watch(selectedTabProvider);
  return tab is HashtagTab ? tab.tag : null;
});

/// デスクトップメニューの「タイムラインを更新」/ `Ctrl+R` (#841) が取り直すべき TL。
///
/// ⚠⚠ **チャンネルタブを忘れない** (#1157)。チャンネルは `ChannelTimelineView`
/// という別の widget が描いており、本線の `RefreshIndicator` がマウントされない。
/// 分岐が無いと `else` に落ちて **画面は変わらないのに裏で本線 TL を取り直す**。
/// 失敗にもならないので気づけない（2026-09-19 にソースで実測）。
///
/// ⚠ 判定の軸は HomeScreen が body を描くときと同じ（[selectedHashtagProvider] /
/// [selectedListProvider]）。ここを別の軸で書くと「出している TL と更新する TL が
/// 違う」が再発する（#925 でそれを避けるために provider 層へ移した経緯がある）。
final currentTimelineRefreshTargetProvider =
    Provider<Refreshable<Future<TimelineState>>>(
      (ref) {
        final account = ref.watch(currentAccountKeyProvider);
        final tab = ref.watch(selectedTabProvider);
        if (tab is ChannelTab) {
          return channelTimelineProvider((account: account, id: tab.id)).future;
        }
        final hashtag = ref.watch(selectedHashtagProvider);
        if (hashtag != null) {
          return hashtagTimelineProvider((
            account: account,
            spec: hashtag,
          )).future;
        }
        final list = ref.watch(selectedListProvider);
        if (list != null) {
          return listTimelineProvider((account: account, id: list.id)).future;
        }
        return timelineProvider(ref.watch(currentTimelineKeyProvider)).future;
      },
      // ⚠ Riverpod は「読む先が dependencies を宣言していたら、それ自身を
      // こちらの dependencies にも載せる」ことを要求する（assert で落ちる）。
      dependencies: [
        currentAccountProvider,
        currentAccountKeyProvider,
        currentTimelineKeyProvider,
        listsProvider,
        selectedListProvider,
        channelTimelineProvider,
        hashtagTimelineProvider,
        listTimelineProvider,
        timelineProvider,
      ],
    );

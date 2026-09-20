import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../provider/channel_provider.dart';
import '../../provider/deck_provider.dart';
import '../../provider/hashtag_provider.dart';
import '../../provider/list_provider.dart';
import '../../provider/preferences_provider.dart';
import '../../provider/tab_selection_provider.dart';
import '../../provider/timeline_provider.dart';
import '../../service/timeline_cache.dart';
import '../../util/exception_scrub.dart';
import '../widget/content_parser.dart';

/// [VisibleTimelineMutator] が持つハッシュタグ TL の反映先。
///
/// spec を添えるのは [VisibleTimelineMutator.insertOwnPost] が「その投稿が
/// そのタグを持つか」を宛先ごとに判定するため。デッキでは違うタグのカラムが
/// 同時に並ぶので、**spec を 1 つだけ覚えておく形では足りない**。
typedef _HashtagTarget = ({HashtagTimelineNotifier notifier, String spec});

/// 投稿の削除・再投稿・差し替えを「いま画面に出ている TL」へ反映するための
/// ハンドル (#887)。
///
/// これまで削除 / 再編集 / タグづけの結果は [timelineProvider]（ホーム・ローカル
/// 等の本線 TL）にしか適用されておらず、**ハッシュタグタブやリストタブを見て
/// いるときは画面が変わらなかった**。本線 TL は streaming で後追い補正されるが、
/// ハッシュタグ / リスト / チャンネルの各 TL は streaming を張っていないため、
/// タブを切り替えて再取得が走るまで古い一覧のままになる（＝報告された「TL を
/// 切り替えると反映される」）。
///
/// ## ⚠⚠ デッキでは反映先が N 本になる (#1099)
///
/// タブ UI は「表示中の TL」が 1 本だったが、デッキは**列にあるカラム全部**が
/// 同時に生きている。ブロックは安全のための操作なので、**1 本だけ消えて他が
/// 残ると保証そのものが破れる**（`docs/deck-ui-plan.md` 未決事項 3 の決着）。
/// 反映先の解決は [readVisibleTimelines] を参照。
///
/// await をまたぐ前に [readVisibleTimelines] で取得しておくこと。widget が
/// dispose された後の `ref.read` は StateError を投げるため (#665)。
class VisibleTimelineMutator {
  /// 本線 TL の変更ハンドル。**反映先が無ければ空**（[readVisibleTimelines]
  /// の判定を参照）。
  final List<TimelineNotifier> _mains;

  /// [_mains] のうち、自分の投稿を楽観的に差し込んでよいもの。⚠ 部分集合。
  final List<TimelineNotifier> _ownPostMains;

  final List<_HashtagTarget> _hashtags;
  final List<ListTimelineNotifier> _lists;
  final List<ChannelTimelineNotifier> _channels;

  const VisibleTimelineMutator._({
    List<TimelineNotifier> mains = const [],
    List<TimelineNotifier> ownPostMains = const [],
    List<_HashtagTarget> hashtags = const [],
    List<ListTimelineNotifier> lists = const [],
    List<ChannelTimelineNotifier> channels = const [],
  }) : _mains = mains,
       _ownPostMains = ownPostMains,
       _hashtags = hashtags,
       _lists = lists,
       _channels = channels;

  /// 削除された投稿を、表示中の TL から取り除く。
  void removePost(String id) {
    for (final main in _mains) {
      main.removePost(id);
    }
    for (final hashtag in _hashtags) {
      hashtag.notifier.removePost(id);
    }
    for (final list in _lists) {
      list.removePost(id);
    }
    for (final channel in _channels) {
      channel.removePost(id);
    }
  }

  /// ブロック / ミュートした相手の投稿を、表示中の TL から取り除く。
  ///
  /// ブロックは安全のための操作なので、「実行したのに画面から消えない」状態を
  /// 残さない。本線 TL は streaming で後追い補正されるが、ハッシュタグ / リスト /
  /// チャンネルの各 TL は張っていないため、ここで消さないとタブを切り替えるまで
  /// 相手の投稿が見えたままになる。
  ///
  /// ⚠⚠ **デッキでは「列にある同じアカウントのカラム全部」から消す**（#1099）。
  /// 可視カラムだけにすると、**画面外のカラムに相手の投稿が残り、横へスクロール
  /// すると出てくる**。反映先の決め方は [readVisibleTimelines]。
  ///
  /// 起動時キャッシュ (#890) も一緒に捨てる。ディスクに残っているのはブロック前の
  /// スナップショットなので、**ブロック直後にアプリを終了して 24 時間以内に
  /// 起動し直すと、REST が返るまでの数百 ms 相手の投稿が先出しされる**。
  /// メモリ上の一覧と未表示バッファだけ掃除しても保証に穴が残る。捨てても次の
  /// TL 取得で書き直されるだけなので、起動体感への影響は次回起動 1 回に留まる。
  ///
  /// ⚠ カラム別スロットになっても**キャッシュは全部捨てる**で通す（B-7 / #1100・
  /// 決着 3-3）。「どのスロットを消すか」を考え始めると、消し忘れが安全の穴になる。
  void removePostsByUser(String userId) {
    for (final main in _mains) {
      main.removePostsByUser(userId);
    }
    for (final hashtag in _hashtags) {
      hashtag.notifier.removePostsByUser(userId);
    }
    for (final list in _lists) {
      list.removePostsByUser(userId);
    }
    for (final channel in _channels) {
      channel.removePostsByUser(userId);
    }
    unawaited(TimelineCache.clear());
  }

  /// 内容が変わった投稿を、表示中の TL で差し替える。
  void updatePost(Post updated) {
    for (final main in _mains) {
      main.updatePost(updated);
    }
    for (final hashtag in _hashtags) {
      hashtag.notifier.updatePost(updated);
    }
    for (final list in _lists) {
      list.updatePost(updated);
    }
    for (final channel in _channels) {
      channel.updatePost(updated);
    }
  }

  /// 投稿直後に自分の投稿を先頭へ楽観的に挿入する (#717 の拡張)。
  ///
  /// ハッシュタグ TL へは、その投稿が**実際にそのタグを持つときだけ**入れる
  /// （AND 指定 `tag+tag2` は全タグ必須）。モロヘイヤがサーバー側で付けたタグも
  /// 投稿結果の本文に載っているので、ここで判定できる。
  ///
  /// リスト / チャンネル TL へは入れない。リストは自分がそのリストのメンバーか
  /// をクライアントから判定できず、チャンネルは投稿側が別途再取得する経路を
  /// 持つため。載らない投稿を差し込むと、リフレッシュで消える幻の投稿になる
  /// (#814)。
  ///
  /// ⚠⚠ **デッキの本線カラムはホームだけが宛先**（[readVisibleTimelines] の
  /// `ownPosts`）。ローカル / 連合 / DM のカラムに入れると、**公開範囲を絞った
  /// 投稿や通常投稿が、載らないはずの TL に幻として出る**。ホームには自分の投稿が
  /// 公開範囲によらず必ず載るので、そこだけ広げる。⚠ **判定できるものだけ広げる**
  /// のは、上のハッシュタグの扱い（#814）と同じ考え方。
  void insertOwnPost(Post post) {
    for (final hashtag in _hashtags) {
      if (postMatchesHashtagSpec(post, hashtag.spec)) {
        hashtag.notifier.insertOwnPost(post);
      }
    }
    for (final main in _ownPostMains) {
      main.insertOwnPost(post);
    }
  }

  /// 反映先を 1 つも持たないハンドル (#990)。
  ///
  /// 呼び出し元の widget が既に dispose されていて、どの TL notifier も取れな
  /// かったときに返す。すべての操作が黙って no-op になる。
  ///
  /// **「反映できない」を「アクションを実行しない」に昇格させないための器**。
  /// 本線 TL は次に表示するとき build() から作り直されるので、ここで取りこぼした
  /// 差し替えは実害にならない（[mainTimelineIsVisible] の doc と同じ理由）。
  static const detached = VisibleTimelineMutator._();
}

/// 投稿がハッシュタグ TL の spec（`tag` / AND 指定 `tag+tag2`）に載るか。
/// タグ名の大小は無視する（Mastodon / Misskey とも大小を区別しない）。
bool postMatchesHashtagSpec(Post post, String spec) {
  final content = post.content;
  if (content == null) return false;
  final tags = extractHashtags(
    content,
    isHtml: post.isHtml,
  ).map((t) => t.toLowerCase()).toSet();
  final (primary, all) = parseHashtagSpec(spec);
  return [primary, ...?all].every((t) => tags.contains(t.toLowerCase()));
}

/// 本線 TL（[timelineProvider]）がいま HomeScreen の body に描かれているか。
///
/// HomeScreen の body 選択は `hashtag ?? list ?? main` で、ハッシュタグでも
/// **解決済み**リストでもないときに本線 TL を出す。チャンネル・通知・お知らせの
/// 各タブは、画面には別のビューが出ていても本線 TL の watch 自体は続いているので
/// 生きている。
///
/// [listResolved] は `selectedListProvider` が非 null の [PostList] を解決できたか。
/// **[ListTab] でも listsProvider 未ロード / id 不一致だと false** で、そのとき
/// HomeScreen は本線 TL にフォールバックして描画している (#925-3)。
///
/// **ここが false のときに `ref.read(timelineProvider.notifier)` を呼んではいけない。**
/// 誰も購読していない autoDispose provider を新しく起こしてしまい、その `build()` が
/// ホーム TL の REST を（可視投稿が集まるまで最大数ページ）叩いて、結果は誰にも
/// 使われないまま破棄される。投稿アクションのたびにこれが走る。
///
/// なお、破棄済み notifier への `state` 代入自体は例外にならず黙って捨てられる
/// （flutter_riverpod 2.6.1 で実測）。本線 TL は次に表示するとき build() から作り
/// 直されるので、ここで触らなくても取りこぼしにはならない。
bool mainTimelineIsVisible(TabType tab, {required bool listResolved}) {
  if (tab is HashtagTab) return false;
  if (tab is ListTab) return !listResolved;
  return true;
}

/// 表示中の TL への変更ハンドルを取得する。**await をまたぐ前に**呼ぶこと。
///
/// 反映先は 2 つの経路から集める。
///
/// ## 1. タブ UI（HomeScreen）
///
/// 判定軸は HomeScreen の描画と同じ派生 provider（[selectedListProvider] /
/// [selectedHashtagProvider]）を共有する (#925-3)。生の `tab is ListTab` で
/// `listTimelineProvider` を触ると、list 未解決の窓（HomeScreen は本線 TL を
/// 描画中）で、誰も watch しない list TL provider を起こして REST を無駄打ちし、
/// しかも変更は実際に見えている本線 TL へ届かない。
///
/// ⚠⚠ **この経路は `ref` がルートのスコープのときだけ**（[inDeckColumnProvider]・
/// #1099）。デッキのカラムは `currentAccountProvider` を上書きした子コンテナで
/// 動くので、そこで `selectedTabProvider`（アカウントに依存しない**単数**の状態）
/// を読むと、**ルートで選ばれているタブを、そのカラムのアカウントに当てた
/// 「誰も見ていない TL」** を起こしてしまう（例: アカウント A のタグタブ ×
/// アカウント B のカラム）。⚠ 現在のアカウントのカラムはルートのコンテナを
/// 共有するので、そこでは HomeScreen ぶんも同じ notifier として解決される。
///
/// ## 2. デッキの列（#1099・`docs/deck-ui-plan.md` 未決事項 3 の決着）
///
/// ⚠⚠ **判定軸は「可視」ではなく「列にある」。**画面外のカラムを外すと、
/// ブロックした相手の投稿がそこに残り、**横へスクロールすると出てくる**。
/// 列にあるカラムの provider は全部生きている（決定済み事項 5-3）ので、
/// `ref.read` で起こしてしまう心配はない。⚠ デッキを閉じると全部片づくため、
/// 列を読むのは [mountedDeckCountProvider] が 0 でない間だけ。
///
/// ⚠⚠ **同じ [AccountKey] のカラムに絞る。**アカウント A でブロックした相手が
/// **アカウント B のカラムには依然として出るのが正しい**（B には B のブロック
/// 関係がある）。⚠ 絞らないと、**同一サーバーに 2 アカウントを持つ人**で誤爆する
/// — `removePostsByUser` が受け取るのは**サーバー内 id** なので、同じサーバーの
/// 別アカウントでは偶然ではなく一致する。
///
/// → ⚠ **関数名の「visible」は実態と合わなくなっている。**デッキでの判定軸は
/// 「可視」ではなく「列にある」。
VisibleTimelineMutator readVisibleTimelines(WidgetRef ref) {
  final account = ref.read(currentAccountKeyProvider);

  final mains = <TimelineNotifier>[];
  final ownPostMains = <TimelineNotifier>[];
  final hashtags = <_HashtagTarget>[];
  final lists = <ListTimelineNotifier>[];
  final channels = <ChannelTimelineNotifier>[];
  // 重複カラム・タブ UI との重なりで同じ notifier が二度入らないようにする
  // （identity で見る）。二度 remove しても害はないが、楽観挿入が二重になる。
  final seen = <Object>{};

  void addMain(TimelineKey key, {required bool ownPosts}) {
    final notifier = ref.read(timelineProvider(key).notifier);
    if (seen.add(notifier)) mains.add(notifier);
    if (ownPosts && !ownPostMains.contains(notifier)) {
      ownPostMains.add(notifier);
    }
  }

  void addHashtag(String spec) {
    final notifier = ref.read(
      hashtagTimelineProvider((account: account, spec: spec)).notifier,
    );
    if (seen.add(notifier)) {
      hashtags.add((notifier: notifier, spec: spec));
    }
  }

  void addList(String id) {
    final notifier = ref.read(
      listTimelineProvider((account: account, id: id)).notifier,
    );
    if (seen.add(notifier)) lists.add(notifier);
  }

  void addChannel(String id) {
    final notifier = ref.read(
      channelTimelineProvider((account: account, id: id)).notifier,
    );
    if (seen.add(notifier)) channels.add(notifier);
  }

  // 1. タブ UI。⚠ ルートのスコープのときだけ（doc 参照）。
  if (!ref.read(inDeckColumnProvider)) {
    final tab = ref.read(selectedTabProvider);
    final resolvedList = ref.read(selectedListProvider);
    if (mainTimelineIsVisible(tab, listResolved: resolvedList != null)) {
      // ⚠ タブ UI は従来どおり種別を問わず楽観挿入の宛先にする（既存の挙動を
      // 変えない）。デッキのカラムだけがホーム限定（[insertOwnPost] の doc）。
      addMain(ref.read(currentTimelineKeyProvider), ownPosts: true);
    }
    if (tab is HashtagTab) addHashtag(tab.tag);
    if (resolvedList != null) addList(resolvedList.id);
    if (tab is ChannelTab) addChannel(tab.id);
  }

  // 2. デッキの列。
  if (ref.read(mountedDeckCountProvider) > 0) {
    for (final column in ref.read(deckColumnsProvider)) {
      // ⚠ 別アカウントのカラムは対象外（doc 参照）。account が null（アカウント
      // 未設定）のときはどのカラムとも一致しない。
      if (column.account != account) continue;
      switch (column.tab) {
        case TimelineTab(:final type):
          addMain((
            account: account,
            type: type,
          ), ownPosts: type == TimelineType.home);
        case HashtagTab(:final tag):
          addHashtag(tag);
        case ListTab(:final id):
          addList(id);
        case ChannelTab(:final id):
          addChannel(id);
        // 通知・お知らせ・デッキ専用（スレッド / プロフィール等）は投稿一覧の
        // notifier を持たないので対象外。⚠ 通知一覧からブロックした相手を消す
        // のは通知側の経路（notification_tile.dart）。
        default:
          break;
      }
    }
  }

  return VisibleTimelineMutator._(
    mains: mains,
    ownPostMains: ownPostMains,
    hashtags: hashtags,
    lists: lists,
    channels: channels,
  );
}

/// dispose 済みの `ref` でも投げない [readVisibleTimelines] (#990)。
///
/// ⚠ **これは「await をまたぐ前に呼ぶ」規約の代わりではなく、最後の砦。**
/// 呼ぶ側は従来どおり await の前に [readVisibleTimelines] を済ませること。
///
/// それでも必要なのは、**await が呼び出し元の外にある**経路があるため。
/// リアクションはボトムシートを開いて絵文字を選んでもらう形で、シートが開いて
/// いる間に背後の TL が更新されると `PostTile` の element が破棄される。以前は
/// ここで StateError が投げられ、しかもその呼び出しがアクション本体 (`action()`)
/// より前にあったため、**リアクションが送信されないまま、成功も失敗も出さずに
/// 消えていた**（Sentry CAPSICUM-4N）。
///
/// 反映先が取れないこと自体は実害が小さい（本線 TL は次に表示するとき build()
/// から作り直される）。取り違えてはいけないのは、**「画面へ反映できない」で
/// 「操作そのものを捨てる」ことの方**。
VisibleTimelineMutator readVisibleTimelinesOrDetached(WidgetRef ref) {
  try {
    return readVisibleTimelines(ref);
  } on StateError catch (e) {
    debugLogException(
      'capsicum: visible timeline unavailable (widget disposed)',
      e,
    );
    return VisibleTimelineMutator.detached;
  }
}

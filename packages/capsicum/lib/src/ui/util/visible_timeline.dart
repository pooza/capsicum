import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/channel_provider.dart';
import '../../provider/hashtag_provider.dart';
import '../../provider/list_provider.dart';
import '../../provider/timeline_provider.dart';
import '../widget/content_parser.dart';

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
/// await をまたぐ前に [readVisibleTimelines] で取得しておくこと。widget が
/// dispose された後の `ref.read` は StateError を投げるため (#665)。
class VisibleTimelineMutator {
  /// 本線 TL の変更ハンドル。**表示されていないときは null**（[readVisibleTimelines]
  /// の判定を参照）。
  final TimelineNotifier? _main;
  final HashtagTimelineNotifier? _hashtag;
  final String? _hashtagSpec;
  final ListTimelineNotifier? _list;
  final ChannelTimelineNotifier? _channel;

  const VisibleTimelineMutator._({
    TimelineNotifier? main,
    HashtagTimelineNotifier? hashtag,
    String? hashtagSpec,
    ListTimelineNotifier? list,
    ChannelTimelineNotifier? channel,
  }) : _main = main,
       _hashtag = hashtag,
       _hashtagSpec = hashtagSpec,
       _list = list,
       _channel = channel;

  /// 削除された投稿を、表示中の TL から取り除く。
  void removePost(String id) {
    _main?.removePost(id);
    _hashtag?.removePost(id);
    _list?.removePost(id);
    _channel?.removePost(id);
  }

  /// 内容が変わった投稿を、表示中の TL で差し替える。
  void updatePost(Post updated) {
    _main?.updatePost(updated);
    _hashtag?.updatePost(updated);
    _list?.updatePost(updated);
    _channel?.updatePost(updated);
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
  void insertOwnPost(Post post) {
    final hashtag = _hashtag;
    final spec = _hashtagSpec;
    if (hashtag != null && spec != null && postMatchesHashtagSpec(post, spec)) {
      hashtag.insertOwnPost(post);
    }
    _main?.insertOwnPost(post);
  }
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

/// 本線 TL（[timelineProvider]）がいま購読されているか。
///
/// HomeScreen が本線 TL を watch するのは「ハッシュタグでもリストでもない」ときだけ
/// で、判定は `build()` の TL 選択と同じ（ハッシュタグ / リストのときはそれぞれの
/// family provider に切り替わる）。チャンネル・通知・お知らせの各タブは、画面には
/// 別のビューが出ていても本線 TL の watch 自体は続いているので生きている。
///
/// **ここが false のときに `ref.read(timelineProvider.notifier)` を呼んではいけない。**
/// 誰も購読していない autoDispose provider を新しく起こしてしまい、その `build()` が
/// ホーム TL の REST を（可視投稿が集まるまで最大数ページ）叩いて、結果は誰にも
/// 使われないまま破棄される。投稿アクションのたびにこれが走る。
///
/// なお、破棄済み notifier への `state` 代入自体は例外にならず黙って捨てられる
/// （flutter_riverpod 2.6.1 で実測）。本線 TL は次に表示するとき build() から作り
/// 直されるので、ここで触らなくても取りこぼしにはならない。
bool mainTimelineIsVisible(TabType tab) =>
    tab is! HashtagTab && tab is! ListTab;

/// 表示中の TL への変更ハンドルを取得する。**await をまたぐ前に**呼ぶこと。
VisibleTimelineMutator readVisibleTimelines(WidgetRef ref) {
  final tab = ref.read(selectedTabProvider);
  return VisibleTimelineMutator._(
    main: mainTimelineIsVisible(tab)
        ? ref.read(timelineProvider.notifier)
        : null,
    hashtag: tab is HashtagTab
        ? ref.read(hashtagTimelineProvider(tab.tag).notifier)
        : null,
    hashtagSpec: tab is HashtagTab ? tab.tag : null,
    list: tab is ListTab
        ? ref.read(listTimelineProvider(tab.id).notifier)
        : null,
    channel: tab is ChannelTab
        ? ref.read(channelTimelineProvider(tab.id).notifier)
        : null,
  );
}

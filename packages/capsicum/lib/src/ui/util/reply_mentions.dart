import 'package:capsicum_core/capsicum_core.dart';

import '../widget/content_parser.dart';

/// 返信の本文の先頭に並べる宛先（`@` を除いた acct）を組む (#1161)。
///
/// Web UI と同じく「返信先の投稿者 → 返信先に含まれるメンション」の順で、
/// 自分と重複を除く。
///
/// - **Mastodon**（`statusToTextMentions`）: メンションは API の `mentions`。
///   自分は ID で除く
/// - **Misskey**（`MkPostForm.vue`）: メンションは返信先の本文の MFM から抜く。
///   ⚠ **host の無いメンションは、返信先の投稿者のサーバーのユーザー**なので、
///   投稿者がリモートならその host を補う
///
/// ⚠⚠ **自分を除く判定は username だけで比べない。**別サーバーの同名ユーザーを
/// 誤って落とす。Misskey は「username が同じ かつ ローカル」のときだけ自分とみなす。
List<String> buildReplyMentions({
  required Post replyTo,
  required User? me,
  required String localHost,
}) {
  final result = <String>[];
  final seen = <String>{};
  void add(String acct) {
    // username / host とも大文字小文字を区別しない（Mastodon も Misskey も）。
    if (seen.add(acct.toLowerCase())) result.add(acct);
  }

  final author = replyTo.author;
  final authorHost = _remoteHost(author.host, localHost);
  if (me == null || author.id != me.id) {
    // ⚠ `userAcct` は使わない。ローカルユーザーの `User.host` には自サーバーの
    // host が入っており、`@user@自サーバー` になって Mastodon の `mentions`
    // （ローカルは `user`）と重複判定がずれる。Web UI と同じくローカルは
    // username だけにする。
    add(
      authorHost == null ? author.username : '${author.username}@$authorHost',
    );
  }

  if (replyTo.isHtml) {
    for (final m in replyTo.mentions) {
      if (me != null && m.id == me.id) continue;
      add(m.acct);
    }
    return result;
  }

  final content = replyTo.content;
  if (content == null || content.isEmpty) return result;
  for (final m in extractMfmMentions(content)) {
    final host = _remoteHost(m.host ?? authorHost, localHost);
    if (me != null &&
        host == null &&
        m.username.toLowerCase() == me.username.toLowerCase()) {
      continue;
    }
    add(host == null ? m.username : '${m.username}@$host');
  }
  return result;
}

/// 投稿フォームが送る指名（`specified`）の宛先 (#1161)。
///
/// - 指名でなければ送らない（空）
/// - ⚠⚠ **redraft は元の投稿の宛先だけを使う。**返信先の宛先を足さない。
///   自分が Web UI 等で宛先を絞った返信を再編集すると、以前は返信先の宛先
///   全員との和集合になり、**外した人に黙って届いていた**（v1.66 リリース前
///   レビューの赤）。宛先は画面に出ないので、利用者は気づけない。⚠ 返信先の
///   取得が送信より先に終わるかどうかで結果が変わる、という揺れも消える
/// - ⚠⚠ **通常の返信では返信先の宛先を引き継がない**（2026-09-21 pooza 判断）。
///   サーバーは返信先の投稿者だけを宛先に足す（`NoteCreateService.ts`）ので、
///   **スレッドの他の人には届かない**（v1.65 までと同じ）。引き継ぐと、capsicum
///   には宛先を見る手段も外す手段も無いまま、本文から消した人にも届く（v1.66
///   リリース前レビュー）。Web UI のように宛先を見せて外せる UI と一緒に
///   入れる（#1165）
/// - どの場合も自分は入れない
List<String> composeVisibleUserIds({
  required PostScope scope,
  required Post? redraft,
  required User? me,
}) {
  if (scope != PostScope.direct) return const [];
  final ids = redraft?.visibleUserIds ?? const <String>[];
  return {...ids}.where((id) => id != me?.id).toList();
}

/// 自サーバーと同じ host はローカル扱い（null）に畳む。
String? _remoteHost(String? host, String localHost) {
  if (host == null || host.isEmpty) return null;
  if (host.toLowerCase() == localHost.toLowerCase()) return null;
  return host;
}

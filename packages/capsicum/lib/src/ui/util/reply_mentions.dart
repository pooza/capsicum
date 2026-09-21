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

/// Misskey の指名（`specified`）への返信で引き継ぐ宛先 (#1161)。
///
/// Web UI と同じく、返信先の宛先と返信先の投稿者から自分を除く。⚠ サーバーが
/// 自動で足すのは返信先の投稿者だけで、**それ以外の宛先は送らないと落ちる**。
List<String> inheritVisibleUserIds({required Post replyTo, required User? me}) {
  final ids = <String>{...replyTo.visibleUserIds, replyTo.author.id};
  if (me != null) ids.remove(me.id);
  return ids.toList();
}

/// 自サーバーと同じ host はローカル扱い（null）に畳む。
String? _remoteHost(String? host, String localHost) {
  if (host == null || host.isEmpty) return null;
  if (host.toLowerCase() == localHost.toLowerCase()) return null;
  return host;
}

import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../model/account.dart';
import '../util/exception_scrub.dart';
import '../util/user_acct.dart';

/// お知らせボット（モロヘイヤの `info_bot`）のフォローを、capsicum の利用者に
/// ついて保つ (#1402)。
///
/// - **自分のサーバーのお知らせボットだけ**が対象。別のサーバーのボットは
///   ふつうに解除できる
/// - capsicum からは外させない（プロフィールで解除・ブロックを出さない →
///   [isOwnInfoBot]）
/// - 外れていれば、ログインしたときと起動したときにフォローし直す
///   （[ensureFollowing]）。⚠ 勧めるだけでは足りない（Misskey のおすすめ
///   ユーザーと同じ不足になる・2026-11-19 pooza）
///
/// ⚠ 本体はサーバー側（pooza/mastodon#1007・pooza/misskey#467 で解除とブロック
/// を拒む）。capsicum 側は、すでに外れている利用者と、フォークが入るまでの
/// サーバーのために残す。
class InfoBotFollowKeeper {
  InfoBotFollowKeeper._();

  /// このプロセスで確かめ終えたアカウント（`AccountKey.toStorageKey()`）。
  /// 復元の再試行や再ログインで何度も呼ばれても、API は 1 回だけ叩く。
  static final _checked = <String>{};

  @visibleForTesting
  static void resetForTesting() => _checked.clear();

  /// `@info@host` / `info@host` を (username, host) に分ける。読めなければ null。
  @visibleForTesting
  static ({String username, String host})? parseAcct(String? acct) {
    if (acct == null) return null;
    final normalized = acct.startsWith('@') ? acct.substring(1) : acct;
    final parts = normalized.split('@');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
    return (username: parts[0], host: parts[1]);
  }

  /// サーバーがフォローの解除・ブロックを拒んだ（フォークの 403）ときの、
  /// 利用者に出す文言。拒まれたのでなければ null。
  ///
  /// ⚠ 両フォークは同じ英文を返す（pooza/mastodon#1007 は `{"error": "…"}`、
  /// pooza/misskey#467 は `{"error": {"message": "…", "code": "…"}}`）。
  /// 英文が一致したときだけ、Mastodon の Web（`alert.protected_follow.*`）と
  /// 同じ日本語に差し替える。
  static String? refusalMessage(Object error) {
    if (error is! DioException || error.response?.statusCode != 403) {
      return null;
    }
    final body = '${error.response?.data}';
    if (!body.contains('is specified by the server')) return null;
    if (body.contains('cannot be unfollowed')) {
      return 'このユーザーはサーバーが指定しているため、フォローを解除できません。';
    }
    if (body.contains('cannot be blocked')) {
      return 'このユーザーはサーバーが指定しているため、ブロックできません。';
    }
    return null;
  }

  /// [user] が、[localHost] のサーバーのお知らせボット（[infoBotAcct]）か。
  ///
  /// ⚠ ボットの acct が別のサーバーを指していたら false（対象は自分の
  /// サーバーのボットだけ）。username と host は大文字小文字を区別しない。
  static bool isOwnInfoBot({
    required User user,
    required String? infoBotAcct,
    required String localHost,
  }) {
    final bot = parseAcct(infoBotAcct);
    if (bot == null) return false;
    if (bot.host.toLowerCase() != localHost.toLowerCase()) return false;
    if (user.username.toLowerCase() != bot.username.toLowerCase()) return false;
    return isLocalHost(user.host, localHost: localHost);
  }

  /// [account] で、自分のサーバーのお知らせボットをフォローしていなければ
  /// フォローする。失敗しても投げない（次に起動したときにまた確かめる）。
  static Future<void> ensureFor(Account account) async {
    final adapter = account.adapter;
    if (adapter is! FollowSupport) return;
    final follow = adapter as FollowSupport;
    if (account.mulukhiya?.infoBotAcct == null) return;
    final key = account.key.toStorageKey();
    if (_checked.contains(key)) return;
    _checked.add(key);
    try {
      final result = await ensureFollowing(
        infoBotAcct: account.mulukhiya?.infoBotAcct,
        localHost: account.key.host,
        ownUsername: account.key.username,
        lookup: adapter.getUser,
        relationship: follow.getRelationship,
        follow: follow.followUser,
      );
      debugPrint('capsicum: info_bot follow: ${result.name}');
    } catch (e) {
      // ⚠ 失敗したら控えから外す。次の復元の再試行や再ログインで確かめ直せる。
      _checked.remove(key);
      debugLogException('capsicum: info_bot follow failed', e);
    }
  }

  /// [ensureFor] の中身。API を関数で受けるのはテストのため。
  @visibleForTesting
  static Future<InfoBotFollowResult> ensureFollowing({
    required String? infoBotAcct,
    required String localHost,
    required String ownUsername,
    required Future<User?> Function(String username, String host) lookup,
    required Future<UserRelationship> Function(String userId) relationship,
    required Future<void> Function(String userId) follow,
  }) async {
    final bot = parseAcct(infoBotAcct);
    if (bot == null) return InfoBotFollowResult.noBot;
    if (bot.host.toLowerCase() != localHost.toLowerCase()) {
      return InfoBotFollowResult.noBot;
    }
    // ボット自身でログインしている。
    if (bot.username.toLowerCase() == ownUsername.toLowerCase()) {
      return InfoBotFollowResult.self;
    }
    final user = await lookup(bot.username, bot.host);
    if (user == null) return InfoBotFollowResult.notFound;
    final rel = await relationship(user.id);
    if (rel.following || rel.requested) return InfoBotFollowResult.following;
    // ⚠ ブロックしている相手はフォローし直さない（ブロックは #1402 の対象外・
    // フォローするとブロックが解けるサーバーがある）。
    if (rel.blocking) return InfoBotFollowResult.blocking;
    await follow(user.id);
    return InfoBotFollowResult.followed;
  }
}

/// [InfoBotFollowKeeper.ensureFollowing] の結果。ログとテストのため。
enum InfoBotFollowResult {
  /// ボットが無い・読めない・別のサーバーのボット。
  noBot,

  /// ボット自身でログインしている。
  self,

  /// ボットのアカウントが見つからない。
  notFound,

  /// もうフォローしている（承認待ちを含む）。
  following,

  /// ブロックしているので触らない。
  blocking,

  /// フォローし直した。
  followed,
}

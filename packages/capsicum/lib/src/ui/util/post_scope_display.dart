import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';

/// UI representation of a [PostScope] — varies between Mastodon and Misskey.
class PostScopeDisplay {
  final String label;
  final IconData icon;

  const PostScopeDisplay({required this.label, required this.icon});
}

/// Whether the given adapter uses Misskey-style naming/icons for scopes.
bool isMisskeyAdapter(BackendAdapter? adapter) => adapter is ReactionSupport;

const _mastodonScopes = {
  PostScope.public: PostScopeDisplay(label: '公開', icon: Icons.public),
  PostScope.unlisted: PostScopeDisplay(
    label: 'ひかえめな公開',
    icon: Icons.nightlight_outlined,
  ),
  PostScope.followersOnly: PostScopeDisplay(
    label: 'フォロワー',
    icon: Icons.lock_outline,
  ),
  PostScope.direct: PostScopeDisplay(
    label: '非公開の返信',
    icon: Icons.alternate_email,
  ),
};

const _misskeyScopes = {
  PostScope.public: PostScopeDisplay(label: 'パブリック', icon: Icons.public),
  PostScope.unlisted: PostScopeDisplay(label: 'ホーム', icon: Icons.home_outlined),
  PostScope.followersOnly: PostScopeDisplay(
    label: 'フォロワー',
    icon: Icons.lock_outline,
  ),
  PostScope.direct: PostScopeDisplay(label: '指名', icon: Icons.mail_outline),
};

/// Returns the display info for [scope] under the current [adapter]'s conventions.
PostScopeDisplay postScopeDisplay(PostScope scope, BackendAdapter? adapter) {
  final table = isMisskeyAdapter(adapter) ? _misskeyScopes : _mastodonScopes;
  return table[scope]!;
}

String postScopeLabel(PostScope scope, BackendAdapter? adapter) =>
    postScopeDisplay(scope, adapter).label;

IconData postScopeIcon(PostScope scope, BackendAdapter? adapter) =>
    postScopeDisplay(scope, adapter).icon;

/// 投稿フォームで選べる公開範囲 (#1043)。
///
/// ⚠ **`PostScope.values` を直接列挙しないこと。**アダプターが送る手段を持って
/// いない範囲まで選択肢に出てしまう。実際 Misskey の「指名」(`specified`) は
/// `visibleUserIds` を送る導線が無いまま選べる状態になっており、選ぶと**誰にも
/// 届かない投稿**ができていた。
///
/// [adapter] が null（アカウント未確定）のときは全件を返す。判断材料が無い
/// 状態で選択肢を削ると、復元中の下書きで選べる範囲が一瞬変わってしまうため。
///
/// ⚠ **受信側の表示はこの関数と無関係。**届いた「指名」投稿の表示
/// (`post_tile.dart` の `isDirect`) は従来どおり動く。塞ぐのは**送る側だけ**。
List<PostScope> selectableScopes(BackendAdapter? adapter) {
  final supported = adapter?.capabilities.supportedScopes;
  if (supported == null) return PostScope.values;
  return PostScope.values.where(supported.contains).toList(growable: false);
}

/// 「指名」を送れない理由。送れるなら null (#1043 / #1117-B)。
///
/// ⚠ **止めるのは「宛先を作れない指名」だけ。**capsicum に宛先の指定画面が無い
/// ので、[selectable] に指名が含まれないサーバー（Misskey）で指名のまま送ると
/// **誰にも届かない**。⚠ **勝手に広い範囲へ倒さない**（以前 `followersOnly` へ
/// 丸めて DM がフォロワー全員に出た）。ユーザーに選び直してもらう。
///
/// ## ⚠⚠ 返信なら無条件に通してよい、ではない (#1117-B)
///
/// サーバーは宛先を補完するが、**補完するのは「返信先の投稿者」だけ**
/// （`NoteCreateService.ts` の `visibleUserIds` 組み立て）。だから
/// **自分のノートへの返信**（指名スレッドの続きを再編集した形）では宛先が自分
/// だけになり、#1043 が防いでいる「誰にも届かない」に逆戻りする。
///
/// - 返信先の投稿者が**自分以外と分かる** → 通す（宛先はその人になる）
/// - 返信先の投稿者が**自分と分かる** → 止める（宛先が自分だけになる）
/// - **分からない**（redraft で取得に失敗した等）→ **通す。**ここで止めると
///   「他人への返信を送れない」を大量に作る。画面側が別途、返信先が取れて
///   いない旨の注記を出している
String? unsendableDirectScopeReason({
  required PostScope scope,
  required List<PostScope> selectable,
  required String directLabel,
  required bool isReply,
  required bool replyTargetIsSelf,
}) {
  if (scope != PostScope.direct) return null;
  if (selectable.contains(PostScope.direct)) return null;
  if (isReply && !replyTargetIsSelf) return null;
  if (isReply) {
    return '「$directLabel」の宛先はサーバーが「返信先の投稿者」から補完しますが、'
        '返信先はあなた自身の投稿です。このままでは自分以外の誰にも届きません。'
        '公開範囲を選び直すか、「メッセージ」をお使いください。';
  }
  return '「$directLabel」は宛先を指定する必要がありますが、capsicum には指定する画面が'
      'ありません。このままでは誰にも届きません。公開範囲を選び直すか、'
      '「メッセージ」をお使いください。';
}

/// Scopes selectable when boosting/renoting a post of the given [originalScope].
///
/// Only `public` originals have multiple choices ({public, unlisted}). Other
/// scopes return an empty list, meaning "no choice — use the default boost".
List<PostScope> boostableScopes(PostScope originalScope) {
  if (originalScope == PostScope.public) {
    return const [PostScope.public, PostScope.unlisted];
  }
  return const [];
}

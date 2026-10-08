import 'package:capsicum_core/capsicum_core.dart';

/// Misskey がリアクションを差し替えるときの代替絵文字 (#1044)。
///
/// ⚠ **サーバーの `core/ReactionService.ts` の `FALLBACK` と同じ文字にする。**
/// 異体字セレクタ付きの `❤️`(U+2764 U+FE0F) ではなく **U+2764 単体**。ずれると
/// 「自分が送ったつもりの絵文字」と「サーバーに載る絵文字」が別物になり、
/// `myReaction` の一致判定が外れる。
const kMisskeyReactionFallback = '❤';

/// リアクションピッカーの出し方 (#1044)。
enum ReactionPickerMode {
  /// 通常どおり全部出す。
  full,

  /// ❤️ しか受け付けられないので、ピッカーを開かず直接送る。
  likeOnly,
}

/// 実際に送るリアクションを決める (#1044)。
///
/// ⚠⚠ **`addReaction` を呼ぶ経路は必ずこれを通す。**判定をピッカーの入口だけに
/// 置いたら、**既存のリアクションチップのタップ・カスタム絵文字のタップ・通知
/// タイルのピッカー**が素通しで残っていた（リリース PR の Codex P1）。それらの
/// 経路ではサーバーが黙って ❤️ へ差し替えるので、直したはずの実害がそのまま
/// 出る。⚠ **#990 で「片方だけに入れて 6 経路を取りこぼした」のと同じ形を、
/// それを警戒すると書いた回に繰り返していた。**
///
/// 受け付けられない絵文字なら [kMisskeyReactionFallback] を返す。呼び出し側は
/// 戻り値をそのまま `addReaction` へ渡すだけでよい。
String effectiveReaction(String reaction, Post post, {String? myHost}) =>
    reactionPickerMode(post, myHost: myHost) == ReactionPickerMode.likeOnly
    ? kMisskeyReactionFallback
    : reaction;

/// [post] の受付条件から、ピッカーの出し方を決める (#1044)。
///
/// ⚠ **サーバーは受け付けられないリアクションをエラーにせず ❤️ へ差し替える。**
/// 成功扱いで返るのでクライアントからは失敗として観測できず、ユーザーには
/// 「押し間違えた？」に見える。**送る前に出し分けるしかない。**
///
/// [myHost] は自分のアカウントのホスト。`likeOnlyForRemote` 系は「投稿の出所の
/// サーバーから見て自分がリモートか」で決まるので、投稿者のホストと突き合わせる。
/// 不明なとき（null）は**制限なしとして扱う** — 判断材料が無い状態で選択肢を
/// 削るより、従来どおりの挙動に倒すほうが害が小さい。
///
/// ⚠ **`nonSensitiveOnly` はここでは弾かない。**この関数は Note だけを見て
/// 「ピッカーを開くかどうか」を決める。センシティブ絵文字は**ピッカーを開いた
/// うえで個別に無効化する**ので、判定は [canReactWith] のほう (#1081)。
ReactionPickerMode reactionPickerMode(Post post, {String? myHost}) {
  final acceptance = post.reactionAcceptance;
  if (acceptance == null) return ReactionPickerMode.full;

  final authorHost = post.author.host;
  final isRemote = myHost != null && authorHost != null && authorHost != myHost;

  switch (acceptance) {
    case ReactionAcceptance.likeOnly:
      return ReactionPickerMode.likeOnly;
    case ReactionAcceptance.likeOnlyForRemote:
    case ReactionAcceptance.nonSensitiveOnlyForLocalLikeOnlyForRemote:
      return isRemote ? ReactionPickerMode.likeOnly : ReactionPickerMode.full;
    case ReactionAcceptance.nonSensitiveOnly:
      return ReactionPickerMode.full;
  }
}

/// [emoji] を [post] へのリアクションに使えるか (#1081)。
///
/// ⚠⚠ **判定の正本は Misskey 本体の `check-reaction-permissions.ts`。**条件は 3 つ
/// あり、**どれか 1 つでも外れると使えない**。サーバーは受け付けられない絵文字を
/// エラーにせず ❤️ へ差し替える（#1044 と同じ構図）ので、**押せてしまうと
/// 「押し間違えた？」に見える**。
///
/// | 条件 | 中身 |
/// | --- | --- |
/// | [CustomEmoji.localOnly] | ローカル限定の絵文字は、**リモートの投稿**には使えない |
/// | [CustomEmoji.isSensitive] | センシティブな絵文字は `nonSensitiveOnly` 系の投稿に使えない |
/// | [CustomEmoji.reactionRoleIds] | 空でなければ、[myRoleIds] のどれかと一致が要る |
///
/// ⚠ **Unicode 絵文字はここを通さない。**上流も「文字列で来たら常に可」としており、
/// 制限はカスタム絵文字にしか掛からない。
///
/// [myHost] / [myRoleIds] が不明なとき（null）は**制限しない側に倒す**。
/// [reactionPickerMode] と同じ方針で、判断材料が無い状態で選択肢を削らない。
///
/// ⚠⚠ **[myRoleIds] は公開ロールしか入らない。**Misskey は `/api/i` の `roles` を
/// `isPublic` で絞って返す（`UserEntityService`）。**非公開ロールで権限を
/// 与えられている人は、使えるのに使えないと判定される。**⚠ これは上流の WebUI も
/// 同じ穴で、capsicum 側だけ緩めると「WebUI では押せないのに capsicum では押せて、
/// サーバーに ❤️ で載る」というより分かりにくい形になるため、**揃えてある**。
/// ⚠ 隠さず**無効化**するのはこのため —— 押せないことが見えれば報告してもらえる。
bool canReactWith(
  CustomEmoji emoji,
  Post post, {
  String? myHost,
  Set<String>? myRoleIds,
}) {
  final authorHost = post.author.host;
  final isRemote = myHost != null && authorHost != null && authorHost != myHost;
  if (emoji.localOnly && isRemote) return false;

  final acceptance = post.reactionAcceptance;
  final nonSensitiveOnly =
      acceptance == ReactionAcceptance.nonSensitiveOnly ||
      acceptance ==
          ReactionAcceptance.nonSensitiveOnlyForLocalLikeOnlyForRemote;
  if (emoji.isSensitive && nonSensitiveOnly) return false;

  if (emoji.reactionRoleIds.isEmpty) return true;
  if (myRoleIds == null) return true;
  return emoji.reactionRoleIds.any(myRoleIds.contains);
}

/// [canReactWith] に渡す自分のロール ID 集合を作る (#1081)。
///
/// **判定できないときは null**（＝制限しない側に倒す）を返す:
///
/// - [me] が無い（未ログイン・取得前）
/// - ⚠⚠ **ロールを持っているのに ID が 1 つも取れない。**`MisskeyUser` の変換は
///   `roles` が無いとき `badgeRoles` へフォールバックし、そちらは **`id` を
///   空文字で埋める**。空文字の集合で突き合わせると**全部「持っていない」に
///   なる**ので、ロール制限つきの絵文字が丸ごと使えなくなる
///
/// ⚠ **ロールが 0 個なのは「判定できない」ではない。**公開ロールを 1 つも
/// 持っていない状態なので、空集合をそのまま返す（制限つき絵文字は使えない）。
Set<String>? reactionRoleIdsOf(User? me) {
  if (me == null) return null;
  final ids = me.roles.map((r) => r.id).where((id) => id.isNotEmpty).toSet();
  if (me.roles.isNotEmpty && ids.isEmpty) return null;
  return ids;
}

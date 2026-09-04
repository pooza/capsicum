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
/// ⚠ **`nonSensitiveOnly` はここでは弾かない。**どのカスタム絵文字が
/// センシティブかは Note ではなく**絵文字カタログ側の情報**で、そちらの拡張が
/// 要る。同時にやると膨らむので分けてある（`likeOnly` 系だけでも「何を押しても
/// ❤️ になる」という最も分かりにくい実害は消える）。
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

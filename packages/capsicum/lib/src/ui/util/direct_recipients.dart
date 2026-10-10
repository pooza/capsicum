/// 指名（Misskey の `specified`）の宛先を、画面で見せて決めるための判定 (#1165)。
///
/// Misskey の指名は、届ける相手を `visibleUserIds`（利用者の id の並び）で渡す。
/// 本文のメンションでは決まらない。以前の capsicum には**宛先を見る手段も外す
/// 手段も無く**、返信先の宛先を引き継ぐと「本文から消した人にも届く」ことに
/// なるので、v1.66 のレビューで引き継ぎごと外した。ここからは宛先を画面に出す
/// ので、引き継いでも、誰に届くかが見えていて外せる。
///
/// ⚠ Mastodon は対象外。宛先は本文のメンションで決まり、adapter もこの値を
/// 読まない。
library;

import 'package:capsicum_core/capsicum_core.dart';

/// 投稿画面を開いたときに入れておく宛先（利用者の id・並び順つき）。
///
/// | 開き方 | 宛先 |
/// | --- | --- |
/// | 削除して再編集 | **元の投稿の宛先だけ**（返信先の宛先を足さない） |
/// | サーバーの下書きから | 下書きに保存した宛先 |
/// | 返信 | 返信先の投稿者。返信先が指名なら、その宛先も |
/// | 新規 | 空 |
///
/// ⚠⚠ **再編集では、返信先の宛先を足さない。**自分が宛先を絞って送った返信を
/// 再編集するとき、返信先の宛先まで足すと、外したはずの人が戻る（v1.66 の
/// リリース前レビューの赤）。⚠ 返信先の取得が間に合うかどうかで結果が変わる、
/// という揺れも無くなる。
///
/// どの場合も自分は入れず、重複は落とす。
List<String> initialDirectRecipientIds({
  required Post? replyTo,
  required Post? redraft,
  required List<String> draftRecipientIds,
  required User? me,
}) {
  final ids = <String>[];
  if (redraft != null) {
    ids.addAll(redraft.visibleUserIds);
  } else if (draftRecipientIds.isNotEmpty) {
    ids.addAll(draftRecipientIds);
  } else if (replyTo != null) {
    ids.add(replyTo.author.id);
    if (replyTo.scope == PostScope.direct) ids.addAll(replyTo.visibleUserIds);
  }
  return {...ids}.where((id) => id != me?.id).toList();
}

/// 外せない宛先の id。無ければ null。
///
/// ⚠⚠ **返信先の投稿者は、外しても届く。**Misskey のサーバーは、指名の返信では
/// 返信先の投稿者を必ず宛先に足す（`NoteCreateService.ts`）。チップだけ消せると
/// 「外したのに届いた」になるので、外せない印を付けて見せる。
///
/// ⚠ 返信先が自分の投稿のときは null（サーバーが足すのは自分で、宛先にならない）。
String? lockedDirectRecipientId({required Post? replyTo, required User? me}) {
  final authorId = replyTo?.author.id;
  if (authorId == null || authorId == me?.id) return null;
  return authorId;
}

/// 指名で送るときに、実際に渡す宛先。指名でなければ空。
List<String> directRecipientIdsToSend({
  required PostScope scope,
  required Iterable<String> recipientIds,
  required User? me,
}) {
  if (scope != PostScope.direct) return const [];
  return {...recipientIds}.where((id) => id != me?.id).toList();
}

/// 宛先を一覧で渡すサーバーで、指名を送れない理由。送れるなら null。
///
/// ⚠ **止めるのは「誰にも届かない」ときだけ。**宛先が 1 人でも居れば送れる。
/// 宛先が空でも、他人の投稿への返信ならサーバーが投稿者を足すので届く
/// （[lockedDirectRecipientId] のとおり、そのときは宛先に投稿者が入っているので、
/// ふつうは空にならない。返信先を読めなかった再編集のための逃げ道）。
String? directRecipientsProblem({
  required PostScope scope,
  required bool hasRecipients,
  required bool isReply,
  required bool replyTargetIsSelf,
  required String directLabel,
}) {
  if (scope != PostScope.direct) return null;
  if (hasRecipients) return null;
  if (isReply && !replyTargetIsSelf) return null;
  return '「$directLabel」の宛先がありません。このままでは誰にも届きません。'
      '「宛先」の ＋ から、届けたい相手を足してください。';
}

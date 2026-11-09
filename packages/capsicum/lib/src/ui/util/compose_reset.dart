import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/services.dart';

import 'hashtag_body.dart';

/// 投稿フォームの「入力を空にする…」(#1368) で戻す先。フォームを開いた時点で
/// 決まった値を控えておく。
///
/// ⚠ **今の既定を読み直さない。**開いたあとにサーバーの既定が変わっても、
/// 戻すのは開いたときの値（2026-11-03 pooza 承認）。
///
/// 扱いの表（Issue の決めごと）:
///
/// | 対象 | 扱い |
/// | --- | --- |
/// | 本文・CW・閲覧注意・添付・アンケート・予約日時 | 消す |
/// | 公開範囲・言語・ローカルのみ・引用の許可・宛先 | 開いたときの値へ戻す |
/// | 返信先・引用先・チャンネル・開いたときのハッシュタグ | 残す |
///
/// ⚠ 閲覧注意と CW 欄の開き方は「消す」側だが、**false ではなくアカウントの
/// 既定へ戻す**（#1194 / #1322）。false にすると、既定で閲覧注意を付けている
/// 人に「付けない」を明示して送ってしまう。
class ComposeOpening {
  const ComposeOpening({
    required this.scope,
    required this.language,
    required this.localOnly,
    required this.quoteApprovalPolicy,
    required this.chosen,
    required this.recipientIds,
    required this.defaultSensitive,
    required this.defaultSpoilerField,
  });

  final PostScope scope;

  /// ⚠ Mastodon の言語は開いた直後のフレームで決まる。その時点で控え直す
  /// （[withLanguage]）。
  final String? language;
  final bool localOnly;
  final String? quoteApprovalPolicy;

  /// 「利用者が選んだ」の印（#1195）。開いた時点ではたいてい空。
  final Set<String> chosen;

  /// 指名の宛先（Misskey）。返信先の投稿者など、開いた理由から決まったもの。
  final List<String> recipientIds;

  /// アカウントの既定の閲覧注意。サーバーが返さなかった / 既定を当てない
  /// 開き方（返信・再編集など）なら null。
  final bool? defaultSensitive;

  /// アカウントの既定で CW 欄を最初から開くか（Mastodon 5.0〜・#1322）。
  final bool defaultSpoilerField;

  ComposeOpening withLanguage(String? language) => ComposeOpening(
    scope: scope,
    language: language,
    localOnly: localOnly,
    quoteApprovalPolicy: quoteApprovalPolicy,
    chosen: chosen,
    recipientIds: recipientIds,
    defaultSensitive: defaultSensitive,
    defaultSpoilerField: defaultSpoilerField,
  );
}

/// 空にしたあとの本文 (#1368)。
///
/// - 返信なら、返信先へのメンション（[replyMentions]・`@` なし）を入れ直す。
///   ⚠ 消すと Mastodon の返信が相手に届かない（返信は残す側なので、メンションも
///   開いたときの形に戻す）
/// - 開いたときに渡されたハッシュタグ（[hashtags]）を入れ直す。カーソルの位置は
///   開いたときと同じ（[initialComposeBody]）
/// - どちらも無ければ空
TextEditingValue composeResetBody({
  List<String> replyMentions = const [],
  List<String> hashtags = const [],
}) {
  if (replyMentions.isNotEmpty) {
    final text = '${replyMentions.map((m) => '@$m').join(' ')} ';
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
  if (hashtags.isNotEmpty) return initialComposeBody(null, hashtags);
  return const TextEditingValue(selection: TextSelection.collapsed(offset: 0));
}

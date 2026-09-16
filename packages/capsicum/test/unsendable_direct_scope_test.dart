import 'package:capsicum/src/ui/util/post_scope_display.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1043 / #1117-B: 「宛先を作れない指名」を送らせない判定。
///
/// ⚠⚠ **「返信なら無条件に通す」では足りなかった。**サーバーが補完するのは
/// **返信先の投稿者だけ**（`NoteCreateService.ts` の `visibleUserIds`）なので、
/// **自分のノートへの返信**では宛先が自分だけになり「誰にも届かない」に逆戻り
/// する。指名スレッドの続きを再編集すると踏む。
///
/// ⚠ **分からないときは通す。**返信先の取得は redraft で失敗しうるので、そこで
/// 止めると「他人への返信を送れない」を大量に作る。
void main() {
  // Misskey 相当（指名を選べない＝宛先の指定画面が無い）。
  const misskeyLike = [
    PostScope.public,
    PostScope.unlisted,
    PostScope.followersOnly,
  ];
  // Mastodon 相当（指名を選べる）。
  const mastodonLike = [...misskeyLike, PostScope.direct];

  String? reasonFor({
    PostScope scope = PostScope.direct,
    List<PostScope> selectable = misskeyLike,
    bool isReply = false,
    bool replyTargetIsSelf = false,
  }) => unsendableDirectScopeReason(
    scope: scope,
    selectable: selectable,
    directLabel: '指名',
    isReply: isReply,
    replyTargetIsSelf: replyTargetIsSelf,
  );

  test('指名でなければ止めない', () {
    expect(reasonFor(scope: PostScope.public), isNull);
    expect(reasonFor(scope: PostScope.followersOnly), isNull);
  });

  test('指名を選べるサーバー（Mastodon）では止めない', () {
    expect(reasonFor(selectable: mastodonLike), isNull);
  });

  test('返信でない指名は止める（宛先を作れない）', () {
    expect(reasonFor(), contains('宛先を指定する必要があります'));
  });

  test('他人への返信は通す（サーバーがその人を宛先に補完する）', () {
    expect(reasonFor(isReply: true), isNull);
  });

  // ⚠⚠ ここが #1117-B の本題。
  test('⚠⚠ 自分の投稿への返信は止める（宛先が自分だけになる）', () {
    final reason = reasonFor(isReply: true, replyTargetIsSelf: true);

    expect(reason, isNotNull);
    expect(reason, contains('返信先はあなた自身の投稿'));
    expect(reason, contains('自分以外の誰にも届きません'));
  });

  test('⚠ 自分への返信でも、指名を選べるサーバーなら止めない', () {
    expect(
      reasonFor(
        selectable: mastodonLike,
        isReply: true,
        replyTargetIsSelf: true,
      ),
      isNull,
    );
  });

  test('⚠ 返信先が分からないときは通す（取得失敗で送信を止めない）', () {
    // 画面側は別途「返信先が取れていない」注記を出している。
    expect(reasonFor(isReply: true), isNull);
  });

  test('理由の文面は「選び直す / メッセージを使う」の 2 択を示す', () {
    for (final reason in [
      reasonFor()!,
      reasonFor(isReply: true, replyTargetIsSelf: true)!,
    ]) {
      expect(reason, contains('公開範囲を選び直す'));
      expect(reason, contains('メッセージ'));
      // ⚠ 勝手に広い範囲へ倒さない方針なので、文面でも「自動で変える」と言わない。
      expect(reason, isNot(contains('自動')));
    }
  });
}

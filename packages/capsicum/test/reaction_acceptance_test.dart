import 'package:capsicum/src/ui/util/reaction_acceptance.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1044 の回帰テスト。
///
/// ⚠ **サーバーは受け付けられないリアクションをエラーにせず ❤️ へ差し替える**
/// ので、この判定が壊れても Sentry にもユーザー報告にも出ない。テストで固定する。
Post _post({
  ReactionAcceptance? acceptance,
  String authorHost = 'example.com',
}) {
  return Post(
    id: '1',
    postedAt: DateTime.utc(2026),
    author: User(id: 'u1', username: 'someone', host: authorHost),
    reactionAcceptance: acceptance,
  );
}

void main() {
  group('reactionPickerMode', () {
    test('受付条件が無ければ全部出す', () {
      expect(
        reactionPickerMode(_post(), myHost: 'example.com'),
        ReactionPickerMode.full,
      );
    });

    test('likeOnly はローカルでもリモートでもピッカーを開かない', () {
      final post = _post(acceptance: ReactionAcceptance.likeOnly);

      expect(
        reactionPickerMode(post, myHost: 'example.com'),
        ReactionPickerMode.likeOnly,
      );
      expect(
        reactionPickerMode(post, myHost: 'other.example'),
        ReactionPickerMode.likeOnly,
      );
    });

    test('likeOnlyForRemote は投稿者と同じホストなら全部出す', () {
      final post = _post(acceptance: ReactionAcceptance.likeOnlyForRemote);

      expect(
        reactionPickerMode(post, myHost: 'example.com'),
        ReactionPickerMode.full,
      );
    });

    test('likeOnlyForRemote は投稿者と別ホストなら ❤️ のみ', () {
      final post = _post(acceptance: ReactionAcceptance.likeOnlyForRemote);

      expect(
        reactionPickerMode(post, myHost: 'other.example'),
        ReactionPickerMode.likeOnly,
      );
    });

    test('nonSensitiveOnlyForLocalLikeOnlyForRemote も同じ分岐', () {
      final post = _post(
        acceptance:
            ReactionAcceptance.nonSensitiveOnlyForLocalLikeOnlyForRemote,
      );

      expect(
        reactionPickerMode(post, myHost: 'example.com'),
        ReactionPickerMode.full,
      );
      expect(
        reactionPickerMode(post, myHost: 'other.example'),
        ReactionPickerMode.likeOnly,
      );
    });

    test('自ホストが不明なら制限なしに倒す', () {
      // 判断材料が無い状態で選択肢を削るより、従来どおりの挙動のほうが害が小さい。
      final post = _post(acceptance: ReactionAcceptance.likeOnlyForRemote);

      expect(reactionPickerMode(post), ReactionPickerMode.full);
    });

    test('nonSensitiveOnly は現状ピッカーを制限しない（絵文字カタログ待ち）', () {
      // どの絵文字がセンシティブかは Note ではなくカタログ側の情報なので、
      // ここでは弾かない。分割した follow-up で拾う。
      final post = _post(acceptance: ReactionAcceptance.nonSensitiveOnly);

      expect(
        reactionPickerMode(post, myHost: 'example.com'),
        ReactionPickerMode.full,
      );
    });

    test('代替絵文字はサーバーの FALLBACK と同じ U+2764 単体', () {
      // 異体字セレクタ付きだと myReaction の一致判定が外れる。
      expect(kMisskeyReactionFallback, '❤');
      expect(kMisskeyReactionFallback.length, 1);
    });
  });
}

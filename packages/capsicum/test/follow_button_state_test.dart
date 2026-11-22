import 'package:capsicum/src/ui/screen/profile_screen.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1400: プロフィールのフォローボタンは 3 状態。
///
/// ⚠ 以前はリクエスト中も「フォロー」と出て、押すとフォローをもう一度送って
/// いた（取り下げる手段も無かった）。
void main() {
  test('フォローしていなければ「フォロー」', () {
    expect(
      followButtonStateOf(const UserRelationship()),
      FollowButtonState.follow,
    );
  });

  test('⚠ リクエスト中なら「リクエスト中」（押すと取り下げ）', () {
    final state = followButtonStateOf(const UserRelationship(requested: true));
    expect(state, FollowButtonState.requested);
    expect(state.label, 'リクエスト中');
  });

  test('フォロー中なら「フォロー解除」', () {
    expect(
      followButtonStateOf(const UserRelationship(following: true)),
      FollowButtonState.unfollow,
    );
  });

  test('両方立っていたらフォロー中として扱う', () {
    expect(
      followButtonStateOf(
        const UserRelationship(following: true, requested: true),
      ),
      FollowButtonState.unfollow,
    );
  });

  // #1403: 「リクエスト中」は状態を表すラベルなので、押したときの動きを添える。
  test('「リクエスト中」にだけ、押すと取り消すことの説明が付く', () {
    expect(FollowButtonState.requested.tooltip, '押すとフォローリクエストを取り消します');
    // ほかはラベルが動作そのもの（「フォロー」「フォロー解除」）なので付けない。
    expect(FollowButtonState.follow.tooltip, isNull);
    expect(FollowButtonState.unfollow.tooltip, isNull);
  });
}

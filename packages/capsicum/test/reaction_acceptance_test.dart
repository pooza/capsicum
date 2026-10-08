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

/// #1081 用。⚠ **3 つとも default は「制限なし」**（サーバーが false / 空を
/// 省くため、欠落をそのまま受けた状態と同じになる）。
CustomEmoji _emoji({
  bool isSensitive = false,
  bool localOnly = false,
  List<String> reactionRoleIds = const [],
}) {
  return CustomEmoji(
    shortcode: 'blobcat',
    url: 'https://example.com/blobcat.png',
    isSensitive: isSensitive,
    localOnly: localOnly,
    reactionRoleIds: reactionRoleIds,
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

    test('nonSensitiveOnly はピッカーを開く（絞るのは canReactWith の仕事・#1081）', () {
      // どの絵文字がセンシティブかは Note ではなくカタログ側の情報なので、
      // この関数（Note しか見ない）では決められない。開いたうえで個別に無効化する。
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

  // #1081: 判定の正本は Misskey 本体の check-reaction-permissions.ts。
  // ⚠ サーバーは受け付けられない絵文字を ❤️ へ差し替えるだけなので、ここが
  // 壊れても Sentry にもユーザー報告にも出ない。
  group('canReactWith', () {
    test('制限の無い絵文字は、受付条件が無ければ使える', () {
      expect(canReactWith(_emoji(), _post(), myHost: 'example.com'), isTrue);
    });

    group('localOnly', () {
      test('ローカル限定の絵文字は、リモートの投稿には使えない', () {
        expect(
          canReactWith(
            _emoji(localOnly: true),
            _post(authorHost: 'other.example'),
            myHost: 'example.com',
          ),
          isFalse,
        );
      });

      test('ローカル限定でも、同じホストの投稿になら使える', () {
        expect(
          canReactWith(
            _emoji(localOnly: true),
            _post(authorHost: 'example.com'),
            myHost: 'example.com',
          ),
          isTrue,
        );
      });

      test('⚠ 自ホストが不明なら制限しない側に倒す', () {
        // reactionPickerMode と同じ方針。判断材料が無い状態で選択肢を削らない。
        expect(
          canReactWith(
            _emoji(localOnly: true),
            _post(authorHost: 'other.example'),
          ),
          isTrue,
        );
      });
    });

    group('isSensitive', () {
      test('nonSensitiveOnly の投稿にセンシティブ絵文字は使えない', () {
        expect(
          canReactWith(
            _emoji(isSensitive: true),
            _post(acceptance: ReactionAcceptance.nonSensitiveOnly),
            myHost: 'example.com',
          ),
          isFalse,
        );
      });

      test('nonSensitiveOnlyForLocalLikeOnlyForRemote でも同じ', () {
        expect(
          canReactWith(
            _emoji(isSensitive: true),
            _post(
              acceptance:
                  ReactionAcceptance.nonSensitiveOnlyForLocalLikeOnlyForRemote,
            ),
            myHost: 'example.com',
          ),
          isFalse,
        );
      });

      test('⚠ 受付条件がセンシティブ禁止でなければ、センシティブ絵文字も使える', () {
        for (final acceptance in <ReactionAcceptance?>[
          null,
          ReactionAcceptance.likeOnlyForRemote,
        ]) {
          expect(
            canReactWith(
              _emoji(isSensitive: true),
              _post(acceptance: acceptance),
              myHost: 'example.com',
            ),
            isTrue,
            reason: '$acceptance',
          );
        }
      });

      test('センシティブでない絵文字は nonSensitiveOnly でも使える', () {
        expect(
          canReactWith(
            _emoji(),
            _post(acceptance: ReactionAcceptance.nonSensitiveOnly),
            myHost: 'example.com',
          ),
          isTrue,
        );
      });
    });

    group('ロール制限', () {
      test('指定ロールを持っていれば使える', () {
        expect(
          canReactWith(
            _emoji(reactionRoleIds: const ['r1', 'r2']),
            _post(),
            myHost: 'example.com',
            myRoleIds: const {'r2'},
          ),
          isTrue,
        );
      });

      test('指定ロールを持っていなければ使えない', () {
        expect(
          canReactWith(
            _emoji(reactionRoleIds: const ['r1']),
            _post(),
            myHost: 'example.com',
            myRoleIds: const {'r9'},
          ),
          isFalse,
        );
      });

      test('⚠ ロールを 1 つも持っていなければ使えない（空集合は「制限なし」ではない）', () {
        expect(
          canReactWith(
            _emoji(reactionRoleIds: const ['r1']),
            _post(),
            myHost: 'example.com',
            myRoleIds: const {},
          ),
          isFalse,
        );
      });

      test('⚠ 自分のロールが不明（null）なら制限しない側に倒す', () {
        expect(
          canReactWith(
            _emoji(reactionRoleIds: const ['r1']),
            _post(),
            myHost: 'example.com',
          ),
          isTrue,
        );
      });

      test('ロール指定が空の絵文字は、ロールを持っていなくても使える', () {
        expect(
          canReactWith(
            _emoji(),
            _post(),
            myHost: 'example.com',
            myRoleIds: const {},
          ),
          isTrue,
        );
      });
    });

    group('reactionRoleIdsOf', () {
      User me({List<UserRole> roles = const []}) =>
          User(id: 'me', username: 'me', host: 'example.com', roles: roles);

      test('自分が分からなければ null（＝制限しない）', () {
        expect(reactionRoleIdsOf(null), isNull);
      });

      test('ロールを 1 つも持っていなければ空集合（＝制限つき絵文字は使えない）', () {
        // ⚠ null（判定できない）とは別物。公開ロールが 0 個という確定情報。
        expect(reactionRoleIdsOf(me()), isEmpty);
      });

      test('ロールの ID を集める', () {
        expect(
          reactionRoleIdsOf(
            me(
              roles: const [
                UserRole(id: 'r1', name: 'モデレータ'),
                UserRole(id: 'r2', name: '常連'),
              ],
            ),
          ),
          {'r1', 'r2'},
        );
      });

      test('⚠⚠ ID が全部空なら null へ倒す（badgeRoles フォールバックで ID が落ちる）', () {
        // 空文字の集合で突き合わせると全部「持っていない」になり、ロール制限
        // つきの絵文字が丸ごと使えなくなる。
        expect(
          reactionRoleIdsOf(
            me(
              roles: const [UserRole(id: '', name: 'バッジ')],
            ),
          ),
          isNull,
        );
      });

      test('⚠ 一部でも ID が取れていれば、それを使う', () {
        expect(
          reactionRoleIdsOf(
            me(
              roles: const [
                UserRole(id: '', name: 'バッジ'),
                UserRole(id: 'r1', name: '常連'),
              ],
            ),
          ),
          {'r1'},
        );
      });
    });

    test('⚠⚠ 条件は AND。1 つでも外れれば使えない', () {
      // ロールは満たすが、リモートの投稿にローカル限定絵文字を使おうとしている。
      expect(
        canReactWith(
          _emoji(localOnly: true, reactionRoleIds: const ['r1']),
          _post(authorHost: 'other.example'),
          myHost: 'example.com',
          myRoleIds: const {'r1'},
        ),
        isFalse,
      );
    });
  });
}

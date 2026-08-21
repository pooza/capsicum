import 'package:capsicum/src/ui/util/attachment_description_edit.dart';
import 'package:flutter_test/flutter_test.dart';

/// #121: 投稿済みメディアの ALT 編集を出してよいかの判定。
///
/// ⚠ **この検査の眼目は「モロヘイヤがいない Mastodon で出さないこと」。**
/// Mastodon は投稿の更新 API 経由でしか投稿済み添付の説明を変えられず、その API
/// は送らなかったパラメータを**空で更新**として扱う。モロヘイヤ 5.34.0 以降が
/// `status` / `spoiler_text` / `sensitive` / `media_ids` を補完して初めて安全に
/// なる（mulukhiya#4589）。補完なしに通すと、ALT が反映されないどころか
/// **添付が全部外れ CW と閲覧注意も消える**。
void main() {
  bool can({
    bool supportsMediaUpdate = true,
    bool needsMulukhiya = true,
    bool hasMulukhiya = true,
    bool isOwnPost = true,
    bool hasPostContext = true,
  }) => canEditAttachmentDescription(
    supportsMediaUpdate: supportsMediaUpdate,
    needsMulukhiya: needsMulukhiya,
    hasMulukhiya: hasMulukhiya,
    isOwnPost: isOwnPost,
    hasPostContext: hasPostContext,
  );

  group('Mastodon（モロヘイヤの補完が要る）', () {
    test('モロヘイヤがいれば出す', () {
      expect(can(), isTrue);
    });

    test('モロヘイヤがいなければ出さない', () {
      expect(
        can(hasMulukhiya: false),
        isFalse,
        reason: '補完なしで通すと添付が全部外れ CW も消える（mulukhiya#4589）',
      );
    });
  });

  group('Misskey（drive/files/update が投稿済みでも効く）', () {
    test('モロヘイヤがいなくても出す', () {
      expect(can(needsMulukhiya: false, hasMulukhiya: false), isTrue);
    });
  });

  test('MediaUpdateSupport を持たないバックエンドでは出さない', () {
    expect(can(supportsMediaUpdate: false), isFalse);
  });

  test('他人の投稿では出さない', () {
    expect(can(isOwnPost: false), isFalse);
  });

  /// メディアビューアは投稿を伴わない経路（ドライブ等）からも開く。
  test('投稿の文脈が無ければ出さない', () {
    expect(can(hasPostContext: false), isFalse);
  });

  /// 条件は AND なので、1 つでも欠ければ他が揃っていても出ない。
  test('投稿の文脈が無ければ、他が揃っていても出さない', () {
    expect(
      can(hasPostContext: false, needsMulukhiya: false),
      isFalse,
      reason: 'Misskey でも投稿 id が無ければ更新先が決まらない',
    );
  });
}

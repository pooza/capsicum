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
    bool mulukhiyaHandlesMediaUpdate = true,
    bool isOwnPost = true,
    bool hasPostContext = true,
  }) => canEditAttachmentDescription(
    supportsMediaUpdate: supportsMediaUpdate,
    needsMulukhiya: needsMulukhiya,
    hasMulukhiya: hasMulukhiya,
    mulukhiyaHandlesMediaUpdate: mulukhiyaHandlesMediaUpdate,
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

    // ⚠ **#999 の本題。**「いるか」だけを見ていたため、補完を持たない 5.33.0 でも
    // 導線が出ていた（自前 4 サーバーが全部これだった）。5.33.0 は
    // media_update を受理してしまい、nginx の map も 405 で止めないので、
    // 出した時点で投稿が壊れる経路が開く。
    test('モロヘイヤがいても補完を持たない版なら出さない', () {
      expect(
        can(mulukhiyaHandlesMediaUpdate: false),
        isFalse,
        reason: '5.33.0 は media_update を受理するが media_ids 等を補完しない',
      );
    });
  });

  group('モロヘイヤの版判定 (#999)', () {
    test('5.34.0 以降は補完を持つ', () {
      expect(mulukhiyaSupportsMediaUpdate('5.34.0'), isTrue);
      expect(mulukhiyaSupportsMediaUpdate('5.34.1'), isTrue);
      expect(mulukhiyaSupportsMediaUpdate('6.0.0'), isTrue);
    });

    test('5.34.0 未満は持たない', () {
      expect(mulukhiyaSupportsMediaUpdate('5.33.0'), isFalse);
      expect(mulukhiyaSupportsMediaUpdate('5.9.0'), isFalse);
      expect(
        mulukhiyaSupportsMediaUpdate('5.33.99'),
        isFalse,
        reason: 'minor が下なら patch がいくつでも未満',
      );
    });

    // ⚠ **「分からない」は「出さない」に倒す。**判定を誤る側の代償が
    // 「投稿が壊れる」なので、版が読めないときに通してはいけない。
    test('版が無い・読めないときは出さない', () {
      expect(mulukhiyaSupportsMediaUpdate(null), isFalse);
      expect(mulukhiyaSupportsMediaUpdate(''), isFalse);
      expect(mulukhiyaSupportsMediaUpdate('unknown'), isFalse);
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

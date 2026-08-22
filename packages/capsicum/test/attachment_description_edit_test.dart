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

  // ⚠ **版番号では判定しない (#999 / mulukhiya#4636)。**動く構成かどうかは
  // モロヘイヤが刺している ginseng-fediverse の版で決まり、`package.version` から
  // は区別できない:
  //
  // - 5.33.0 … `media_update` を受理するが `media_ids` / `spoiler_text` /
  //   `sensitive` を補完しない → **投稿から添付が全部外れ CW も消える**
  // - 5.34.0 … 補完はするが上流 PUT に `X-Mulukhiya` が付かず **405 で失敗**
  //   （ginseng-fediverse#254 / 1.8.30 で修正・5.35.0 に載る）
  //
  // どちらも外からは「5.3x」としか名乗らないので、モロヘイヤ側のフラグを見る。
  group('モロヘイヤのフラグ判定 (#999)', () {
    test('フラグを名乗らないサーバーでは出さない', () {
      expect(
        can(mulukhiyaHandlesMediaUpdate: false),
        isFalse,
        reason: '5.33.0 なら投稿が壊れ、5.34.0 なら 405 で失敗する',
      );
    });

    test('フラグを名乗るサーバーでだけ出す', () {
      expect(can(mulukhiyaHandlesMediaUpdate: true), isTrue);
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

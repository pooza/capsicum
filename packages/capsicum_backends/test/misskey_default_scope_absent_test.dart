import 'package:capsicum_backends/src/misskey/extensions.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// #1185-2: Misskey の `defaultNoteVisibility` は死にコードだった。
///
/// ⚠⚠ **この値は Misskey の API に存在したことが無い。**`packages/backend` にも
/// `misskey-js` にも無く、`git log -S` で追っても **frontend のクライアント設定
/// (`preferences/def.ts`) にしか現れない**。にもかかわらず capsicum は
/// `MisskeyUser.defaultNoteVisibility` を持ち、`toCapsicum` で
/// `User.defaultScope` へ写していた。サーバーが送らないので**常に null**。
///
/// ⚠ **実害は無かった**（`compose_screen` は `defaultScope != null` のときだけ
/// 使い、null なら capsicum 側の既定へ倒れる）が、**誤解の元**なので消した。
///
/// ここが見るのは「消えたまま戻らないこと」。⚠ **サーバーが送ってきても
/// `defaultScope` が埋まらない**ことまで見るのが肝で、「キーを知らない」ではなく
/// 「写さない」を固定する。既定の公開範囲をサーバーから読めるのは Mastodon の
/// `source.privacy` だけ（`docs/server-settings-gap-inventory.md` §5-2）。
void main() {
  MisskeyUser user(Map<String, dynamic> overrides) =>
      MisskeyUser.fromJson({'id': '1', 'username': 'capsicum', ...overrides});

  group('MisskeyUser.toCapsicum — defaultScope', () {
    test('素の user では defaultScope が null', () {
      expect(user({}).toCapsicum('misskey.example').defaultScope, isNull);
    });

    // ⚠⚠ **歯はここ。**「フィールドを消しただけ」だと、誰かが
    // `defaultNoteVisibility` を足し直したときに黙って復活する。サーバーが
    // 送ってきても写さないことを固定する。
    test('⚠⚠ defaultNoteVisibility が来ても defaultScope は埋まらない', () {
      final mapped = user({
        'defaultNoteVisibility': 'home',
      }).toCapsicum('misskey.example');

      expect(
        mapped.defaultScope,
        isNull,
        reason: 'Misskey は既定の公開範囲を API で返さない。写すと誤解が復活する',
      );
    });

    // 対照群。rosetta そのものは生きている（投稿の visibility 変換で使う）ので、
    // 「rosetta を消した」ことで上が通っているのではないことを示す。
    test('visibility の rosetta 自体は生きている（対照群）', () {
      expect(misskeyVisibilityRosetta['home'], PostScope.unlisted);
      expect(misskeyVisibilityRosetta['public'], PostScope.public);
    });
  });
}

import 'package:capsicum/src/ui/util/post_scope_display.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1043 の回帰テスト。
///
/// 「送る手段が無いのに選択肢だけ出ている」状態を作らないことを固定する。
/// ⚠ **`PostScope.values` を UI が直接列挙していたのが原因**だったので、
/// ここで守るのは「アダプターの `supportedScopes` が母数になっていること」。
void main() {
  group('selectableScopes', () {
    test('Misskey は「指名」を選択肢に出さない', () async {
      final adapter = await MisskeyAdapter.create('misskey.io');
      final scopes = selectableScopes(adapter);

      expect(scopes, isNot(contains(PostScope.direct)));
      expect(scopes, contains(PostScope.public));
      expect(scopes, contains(PostScope.unlisted));
      expect(scopes, contains(PostScope.followersOnly));
    });

    test('Mastodon は「非公開の返信」を選択肢に出す', () async {
      final adapter = await MastodonAdapter.create('mastodon.social');

      // Mastodon は宛先をメンションで表現するので、追加の導線なしに送れる。
      expect(selectableScopes(adapter), contains(PostScope.direct));
    });

    test('アダプター未確定（null）のときは全件を返す', () {
      // 判断材料が無い状態で削ると、下書きの復元中に選べる範囲が一瞬変わる。
      expect(selectableScopes(null), PostScope.values);
    });

    test('並び順は PostScope.values を保つ', () async {
      // 公開範囲は「広い → 狭い」の順で並んでいる前提の UI なので、
      // 絞り込みで順序が入れ替わらないことを固定する。
      final adapter = await MisskeyAdapter.create('misskey.io');
      final scopes = selectableScopes(adapter);

      final expected = PostScope.values
          .where(scopes.contains)
          .toList(growable: false);
      expect(scopes, expected);
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1083-E: `reportOpFailure` の `tagKey` の形を機械で守る。
///
/// 規約は `<領域>.op` か `<領域>.<経路>` の 2 型だけ（正本は
/// `service/sentry_op_failure.dart` の doc）。
///
/// ⚠ **実害は「見つけにくさ」に出る。**fingerprint は
/// `[tagKey, operation, 例外型]` なので群の数は変わらず、**壊れても Sentry は
/// 普通に動いているように見える**。効くのはファセットで横断クエリを書くとき
/// だけなので、規約から外れても誰も気づかない。だから機械で見る。
///
/// ## ⚠⚠ リテラルだけ見ていたので、実際に踏んだ 2 件を捕まえていなかった (#1117-D)
///
/// 旧実装は `tagKey:\s*'…'` しか拾わなかった。ところが `moderation.blocks` /
/// `moderation.mutes` は**別の名前の引数へリテラルを渡し**（`tag: 'moderation.blocks'`）、
/// それを `tagKey: widget.kind.tag` と**転送**していた。⚠ **doc は「3 件を塞ぐ」と
/// 書いていたが、実際に当たるのは 2 件だけ**だった（修正前のソースを食わせて確認）。
///
/// そこで **`tagKey:` に渡している非リテラルは、同一ファイル内で辿る**ようにした。
/// 辿れなければ違反（＝形を確かめられない値を tagKey に渡させない）。
void main() {
  /// 非リテラルの `tagKey:` 引数のうち、**転送として許すもの**の名前。
  ///
  /// ⚠ `tagKey: widget.tagKey` は「呼び出し側から来た値をそのまま渡す」形で、
  /// 呼び出し側は別ファイルの `tagKey: '…'` として**この走査に入っている**。
  /// ここで違反にすると、集約ウィジェット（`CursorPagedListView`）が書けない。
  const forwardNames = {'tagKey'};

  /// 1 ファイルから `tagKey` に渡っている文字列を集める。
  ///
  /// ⚠ **コメントを潰してから見る**（`test/support/dart_source.dart`）。例示の
  /// ためコメントに書いた `tagKey: 'foo'` を違反として数えない。
  ///
  /// 戻り値の `key` が null なのは「非リテラルで、同一ファイル内で辿れなかった」
  /// もの。呼び出し側はそれ自体を違反として扱う。
  List<(String key, bool resolved)> tagKeysIn(String source) {
    final code = maskComments(source);
    final out = <(String, bool)>[];

    // 1. 素のリテラル。
    for (final m in RegExp(r"""tagKey:\s*'([^']*)'""").allMatches(code)) {
      out.add((m.group(1)!, true));
    }

    // 2. 非リテラル（識別子 / メンバ参照）。
    final nonLiteral = RegExp(r'tagKey:\s*([A-Za-z_][A-Za-z0-9_.]*)');
    for (final m in nonLiteral.allMatches(code)) {
      final expr = m.group(1)!;
      // ⚠ **最後の名前だけを見る。**`widget.kind.tag` が指す値は、同一ファイルで
      // `tag:` へ渡されているリテラル（＝enum 相当の定義）に辿れる。
      final name = expr.split('.').last;
      if (forwardNames.contains(name)) continue;

      // 同一ファイル内の定義を辿る。
      final escaped = RegExp.escape(name);
      final literals = [
        // `const _moderationTagKey = 'moderation.op';`
        for (final d in RegExp(
          "(?:const|final|var)\\s+$escaped\\s*=\\s*'([^']*)'",
        ).allMatches(code))
          d.group(1)!,
        // `tag: 'moderation.blocks',`（別名の引数へ渡してから転送する形）
        for (final d in RegExp(
          "(?<![A-Za-z0-9_])$escaped:\\s*'([^']*)'",
        ).allMatches(code))
          d.group(1)!,
      ];
      if (literals.isEmpty) {
        out.add((expr, false));
        continue;
      }
      for (final literal in literals) {
        out.add((literal, true));
      }
    }
    return out;
  }

  /// `lib` 全体。パスつきで返す。
  List<(String path, String key, bool resolved)> tagKeys() {
    final out = <(String, String, bool)>[];
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      for (final (key, resolved) in tagKeysIn(file.readAsStringSync())) {
        out.add((file.path, key, resolved));
      }
    }
    return out;
  }

  /// 規約に合う形か。`<領域>.op` / `<領域>.<経路>`（小文字と `_` のみ）。
  bool wellShaped(String key) =>
      RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$').hasMatch(key);

  /// 「一覧の対象」を後半に置いた形。
  ///
  /// ⚠ **形だけでは弾けない。**`moderation.blocks` は `<領域>.<経路>` として
  /// 正しい形をしているので、[wellShaped] は true を返す。網羅ではなく、
  /// **実際に踏んだ形**を再発させないための歯。
  const objectLike = {'blocks', 'mutes', 'followed', 'favorites', 'requests'};

  /// 規約違反か。⚠ **判定は 1 本にする。**合成テストと実リポジトリの走査で
  /// 別の判定を書くと、「テストは通るのに本番の走査は素通り」が起きる。
  bool violates(String key) =>
      !wellShaped(key) || objectLike.contains(key.split('.').last);

  test('走査が空振りしていない', () {
    final keys = tagKeys();
    // ⚠ 0 件でも「違反なし」で緑になる。実数で固定する。
    expect(
      keys.length,
      greaterThan(10),
      reason: 'tagKey の呼び出しが見つからない。正規表現が実装の書き方と合っていない',
    );
    // 既知の代表例が拾えていること。ここが落ちたら数え方が変わっている。
    expect(keys.map((e) => e.$2), containsAll(['chat.op', 'drive.op']));
    // ⚠ **非リテラルの転送も拾えていること (#1117-D)。**`const _moderationTagKey`
    // を辿れなくなったら、この形の違反が見えなくなる。
    expect(
      keys.map((e) => e.$2),
      contains('moderation.op'),
      reason: '同一ファイルの const を辿れていない',
    );
  });

  test('判定に歯がある（合成した形で確かめる）', () {
    // 当たるべきでない形（規約どおり）。
    for (final ok in const [
      'chat.op',
      'drive.op',
      'chat.load_more',
      'hashtag.op',
      'hashtag.list',
      'moderation.op',
      'follow_request.op',
      'notification.unified',
    ]) {
      expect(violates(ok), isFalse, reason: ok);
    }
    // 当たるべき形。⚠ **実際に直した 3 つをそのまま並べる**（想定した書き方
    // しか並べないと、実物の形を取りこぼしても気づけない）。
    for (final ng in const [
      'follow_request', // ドット無し
      'moderation.blocks', // 対象をキーにしている（形は正しいので後半で弾く）
      'moderation.mutes',
      'hashtag.followed',
      'Chat.Op', // 大文字
      'chat.', // 空の後半
      '.op',
    ]) {
      expect(violates(ng), isTrue, reason: ng);
    }
  });

  group('走査に歯がある（合成したソースで確かめる）', () {
    test('リテラルを拾う', () {
      expect(tagKeysIn("reportOpFailure(tagKey: 'moderation.blocks');"), [
        ('moderation.blocks', true),
      ]);
    });

    // ⚠⚠ これが #1117-D の本題。旧実装はこの形を 1 件も拾わなかった。
    test('⚠⚠ 別名の引数へ渡してから転送する形を拾う', () {
      const source = '''
class _Kind {
  const _Kind({required this.tag});
  final String tag;
}
const _blocks = _Kind(tag: 'moderation.blocks');
Widget build() => CursorPagedListView(tagKey: widget.kind.tag);
''';

      expect(tagKeysIn(source).map((e) => e.$1), contains('moderation.blocks'));
    });

    test('同一ファイルの const を辿る', () {
      const source = '''
const _moderationTagKey = 'moderation.blocks';
Widget build() => CursorPagedListView(tagKey: _moderationTagKey);
''';

      expect(tagKeysIn(source), contains(('moderation.blocks', true)));
    });

    // ⚠ 集約ウィジェットの転送は許す（呼び出し側が走査に入っている）。
    test('widget.tagKey の転送は辿れなくても違反にしない', () {
      expect(tagKeysIn('reportOpFailure(tagKey: widget.tagKey);'), isEmpty);
    });

    test('⚠ 辿れない値は違反として出す', () {
      final found = tagKeysIn('reportOpFailure(tagKey: someUnknown.value);');

      expect(found.length, 1);
      expect(found.single.$2, isFalse, reason: '辿れないので形を確かめられない');
    });

    test('コメントの中の例示は拾わない', () {
      expect(
        tagKeysIn("// reportOpFailure(tagKey: 'moderation.blocks');"),
        isEmpty,
      );
    });
  });

  // ⚠⚠ **修正前のソースを実際に食わせる (#1117-D)。**合成ソースは「想定した
  // 書き方」しか並べられないので、**実物で当たることを確かめる**。これが無いと
  // 「doc は 3 件を塞ぐと書いてあるのに実際は 2 件」という食い違いに気づけない。
  test('⚠⚠ 修正前の moderation_list_screen を食わせると当たる', () {
    // tagKey を直した commit の親。
    const preFix = '11d19821^';
    const path =
        'packages/capsicum/lib/src/ui/screen/moderation_list_screen.dart';
    final shown = Process.runSync('git', [
      '-C',
      '../..',
      'show',
      '$preFix:$path',
    ]);
    // ⚠ shallow clone 等で履歴が無い環境では skip する（検査の本体は上の合成
    // ソース側にある）。
    if (shown.exitCode != 0) {
      markTestSkipped('git show が使えない: ${shown.stderr}');
      return;
    }

    final found = tagKeysIn(shown.stdout as String);
    final offenders = [
      for (final (key, resolved) in found)
        if (!resolved || violates(key)) key,
    ];

    expect(
      offenders,
      containsAll(['moderation.blocks', 'moderation.mutes']),
      reason: '修正前の形を捕まえられない走査は、同じ間違いを次も通す',
    );
  });

  test('tagKey は <領域>.op か <領域>.<経路> の形をしている', () {
    final offenders = [
      for (final (path, key, resolved) in tagKeys())
        if (!resolved)
          '$path: $key（同一ファイル内で辿れない。リテラルか同一ファイルの const にすること）'
        else if (violates(key))
          '$path: $key',
    ];
    expect(
      offenders,
      isEmpty,
      reason:
          'tagKey は「op の系統」を表す。対象（何の一覧か）ではない。'
          '何をしたかは operation に置く（正本: sentry_op_failure.dart の doc）'
          '\n${offenders.join('\n')}',
    );
  });
}

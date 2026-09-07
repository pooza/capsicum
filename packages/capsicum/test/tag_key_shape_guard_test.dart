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
/// 実際に 3 つ外れていた:
///
/// | 現状（修正前） | 何が違うか |
/// | --- | --- |
/// | `follow_request` | リポジトリ唯一のドット無し |
/// | `moderation.blocks` / `moderation.mutes` | **対象**をキーにしていた（op の系統ではない） |
/// | `hashtag.followed` | 同上 |
void main() {
  /// `tagKey:` に渡している文字列リテラルを、パスつきで数え上げる。
  ///
  /// ⚠ **コメントを潰してから見る**（`test/support/dart_source.dart`）。
  /// 例示のためコメントに書いた `tagKey: 'foo'` を違反として数えない。
  List<(String path, String key)> tagKeys() {
    final out = <(String, String)>[];
    final pattern = RegExp(r"""tagKey:\s*'([^']*)'""");
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      final code = maskComments(file.readAsStringSync());
      for (final m in pattern.allMatches(code)) {
        out.add((file.path, m.group(1)!));
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

  test('tagKey は <領域>.op か <領域>.<経路> の形をしている', () {
    final offenders = [
      for (final (path, key) in tagKeys())
        if (violates(key)) '$path: $key',
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

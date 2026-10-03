import 'dart:io';

import 'package:capsicum/src/ui/util/compose_settings_display.dart';
import 'package:capsicum/src/ui/util/post_scope_display.dart';
import 'package:capsicum/src/ui/widget/overflow_icon_row.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1167（案 B）: 狭い幅で送信時の設定を 1 段へ詰めるときの取り決め。
///
/// ⚠⚠ **守る条件は「設定を畳まない」。**案 3+2 で設定を別行へ出したが、iPhone 13
/// mini（375pt）ではその行自体が折り返して**下のツールバーが 3 段**になった
/// （2026-09-28 実測）。案 B は 1 段にまとめるが、⚠ **畳んで見えなくするのでは
/// なく「詰める」**（見えないまま効いているのは #1167 の元の不具合そのもの）。
void main() {
  group('詰めたラベル (#1167)', () {
    test('5 文字まではそのまま', () {
      expect(compactSettingLabel('公開'), '公開');
      expect(compactSettingLabel('ホーム'), 'ホーム');
      expect(compactSettingLabel('指名'), '指名');
      expect(compactSettingLabel('フォロワー'), 'フォロワー');
      expect(compactSettingLabel('パブリック'), 'パブリック');
    });

    test('⚠ 6 文字以上は先頭 4 文字 + …', () {
      expect(compactSettingLabel('非公開の返信'), '非公開の…');
      expect(compactSettingLabel('ひかえめな公開'), 'ひかえめ…');
    });

    test('⚠ 略語を作らない（切るだけ・新しい語を生まない）', () {
      // ⚠⚠ `docs/CLAUDE.md` の用語統一表が正本。「ひかえめな公開」を「ひかえめ」と
      // 呼ぶと**用語が二重管理**になるので、省略記号で機械的に切る形にしてある
      // （2026-09-29 pooza 決定）。
      expect(compactSettingLabel('ひかえめな公開'), isNot('ひかえめ'));
      expect(compactSettingLabel('非公開の返信'), isNot('非公開'));
      expect(compactSettingLabel('ひかえめな公開'), endsWith('…'));
    });

    test('詰めた形は必ず 5 文字以内（1 段に収める前提）', () {
      for (final label in [
        '公開',
        'ひかえめな公開',
        'フォロワー',
        '非公開の返信',
        'パブリック',
        'ホーム',
        '指名',
        'とても長い公開範囲の名前',
      ]) {
        expect(
          compactSettingLabel(label).runes.length,
          lessThanOrEqualTo(5),
          reason: label,
        );
      }
    });

    test('⚠ 空文字・1 文字でも壊れない', () {
      expect(compactSettingLabel(''), '');
      expect(compactSettingLabel('公'), '公');
    });
  });

  group('⚠ 実際の公開範囲ラベルに当てる (#1167)', () {
    // ⚠ **合成した文字列ではなく実物を通す。**上流の用語が変わったとき、
    // 「詰めた結果が読めるか」はこちらでしか分からない。
    test('Misskey は全部そのまま（詰めても何も変わらない）', () {
      for (final scope in PostScope.values) {
        final label = postScopeLabel(scope, _MisskeyLike());
        expect(
          compactSettingLabel(label),
          label,
          reason: '⚠ Misskey の範囲は全部 5 文字以内。変わったら詰め方を見直す',
        );
      }
    });

    test('⚠ Mastodon で詰まるのは 2 つだけ', () {
      final shortened = <String>[];
      for (final scope in PostScope.values) {
        final label = postScopeLabel(scope, null);
        if (compactSettingLabel(label) != label) shortened.add(label);
      }
      expect(shortened, ['ひかえめな公開', '非公開の返信']);
    });
  });

  group('⚠⚠ 幅の定数が対になっている (#1167)', () {
    test('「…」1 個ぶんの確保は OverflowIconRow の 1 つぶんと同じ', () {
      // ⚠⚠ **ここが食い違うと「…」が出せなくなる。**設定に幅を渡しすぎると
      // アイコン列が 1 つぶんを下回り、`visibleCountFor` が 0 を返したうえで
      // 「…」の場所も無い、という状態になる。
      const row = OverflowIconRow(actions: []);
      expect(kComposeToolbarMinIconRowWidth, row.itemExtent);
    });

    test('⚠ 確保した幅で「…」は必ず出せる', () {
      // 確保は 1 つぶんなので、見えるアイコンは 0 個でよい ——「…」が出れば
      // 畳まれた全部へ手が届く。
      expect(
        OverflowIconRow.visibleCountFor(
          width: kComposeToolbarMinIconRowWidth,
          total: 11,
          itemExtent: kComposeToolbarMinIconRowWidth,
        ),
        0,
      );
    });

    test('⚠ 2 段に戻す境目は、設定がラベル付きで 1 行に収まる幅より広い', () {
      // 見積りの根拠は `compose_settings_display.dart` の doc（Mastodon の最悪
      // ケースで約 330）。⚠ **テキストスケール 1.3 でも折り返さない**ことを
      // 境目の条件にしてある。
      const worstCaseFullWidth = 330.0;
      expect(
        kComposeToolbarTwoRowMinWidth,
        greaterThan(worstCaseFullWidth * 1.3),
      );
      // ⚠ デスクトップの狭幅運用（630px 前後）は 2 段側に残すこと。
      expect(kComposeToolbarTwoRowMinWidth, lessThan(630));
    });
  });

  group('⚠⚠ 引用許可の短縮はキーが本体と 1 対 1 (#1167)', () {
    const path = 'lib/src/ui/screen/compose_screen.dart';
    late String masked;

    setUpAll(() {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: '$path が見つからない');
      masked = maskComments(file.readAsStringSync());
    });

    test('本体のキーを全部持っている', () {
      // ⚠⚠ **片方だけ足すと、詰めた側でその値が欠ける。**`?? entry.value` で
      // フルラベルへ落ちるので**画面は壊れず、ただ 1 段に収まらなくなるだけ** ——
      // 目視では気づけない壊れ方なので機械で見る。
      final keys = _quoteApprovalKeys(masked);
      expect(
        composeQuoteApprovalShortLabels.keys.toSet(),
        containsAll(keys),
        reason: '⚠ `_quoteApprovalLabels` に足したキーを短縮側にも足すこと',
      );
    });

    test('短縮側に余計なキーが無い（消えたキーが残り続けない）', () {
      expect(
        composeQuoteApprovalShortLabels.keys.toSet(),
        _quoteApprovalKeys(masked),
      );
    });

    test('短縮はフルラベル以下の長さ（詰める意味がある）', () {
      for (final entry in composeQuoteApprovalShortLabels.entries) {
        expect(
          entry.value.runes.length,
          lessThanOrEqualTo(5),
          reason: entry.key,
        );
      }
    });

    // ⚠ ここから下は「検査が動いていること」そのものの検査。
    test('走査が空振りしていない（既知のキーが拾えている）', () {
      final keys = _quoteApprovalKeys(masked);
      expect(keys, containsAll(<String>['public', 'followers', 'nobody']));
      expect(keys, hasLength(3), reason: '⚠ 増えたならこの数も上げる');
    });

    test('⚠⚠ キーを 1 つ足すと検出できる（歯の確認）', () {
      const marker = "    'nobody': '許可しない',";
      expect(masked, contains(marker), reason: '差し込み先が実在する');
      final hole = masked.replaceFirst(
        marker,
        "$marker\n    'mutuals': '相互フォローのみ',",
      );
      final keys = _quoteApprovalKeys(hole);
      expect(keys, contains('mutuals'));
      expect(
        composeQuoteApprovalShortLabels.keys.toSet(),
        isNot(containsAll(keys)),
        reason: '⚠⚠ ここが通ってしまうなら、検査は何も見ていない',
      );
    });

    test('⚠ 判定に合成ソースを食わせる', () {
      expect(
        _quoteApprovalKeys("""
  static const _quoteApprovalLabels = {
    'a': 'あ',
    'b': 'い',
  };
"""),
        {'a', 'b'},
      );
      // 別の定数を巻き込まない。
      expect(
        _quoteApprovalKeys("""
  static const _languageOptions = {
    'ja': '日本語',
  };
"""),
        isEmpty,
      );
    });
  });
}

/// `_quoteApprovalLabels` のキー。
Set<String> _quoteApprovalKeys(String masked) {
  final head = masked.indexOf('_quoteApprovalLabels = {');
  if (head < 0) return const {};
  final end = masked.indexOf('};', head);
  if (end < 0) return const {};
  final body = masked.substring(head, end);
  return RegExp(r"'(\w+)':").allMatches(body).map((m) => m.group(1)!).toSet();
}

/// `postScopeLabel` が Misskey 側の表を引くための最小の器。
///
/// ⚠ `isMisskeyAdapter` は `adapter is ReactionSupport` で見るので、
/// **`BackendAdapter` かつ `ReactionSupport`** であれば実サーバーは要らない。
class _MisskeyLike implements BackendAdapter, ReactionSupport {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} は呼ばれない想定');
}

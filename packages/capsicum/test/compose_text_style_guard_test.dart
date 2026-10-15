import 'package:capsicum/src/ui/util/compose_text_style.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/source_files.dart';

/// #1233: 投稿フォームのフォント設定（#892）を、本文を書く欄すべてに当てる。
///
/// 以前は投稿の本文 1 か所にだけ `TextStyle(fontFamily: …)` を直に組んでいて、
/// Annict の感想や投稿テンプレートの本文には当たっていなかった。当て方を
/// `composeTextStyle` の 1 か所へ寄せ、**当てている場所をここで数える**。
///
/// 線引き（どの欄に当てるか）は `compose_text_style.dart` の冒頭にある。

/// 複数行だが、投稿フォームのフォントを当てない入力欄。**1 件ずつ理由を書く。**
/// キーはファイル、値は件数と理由（件数も見るので、黙って足せない）。
const _unstyledMultiline = <String, ({int count, String reason})>{
  'lib/src/ui/screen/image_overlay_screen.dart': (
    count: 1,
    reason:
        '画像に重ねる文字。文章ではなく画像の上に描く素材で、描かれる書体は別に'
        '決まる（compose_text_style.dart の表で「当てない」と決めてある）',
  ),
  'lib/src/ui/widget/emoji_picker.dart': (
    count: 1,
    reason: '絵文字の取り込みで、コピーした設定を貼り付ける欄。文章を書く欄ではない',
  ),
  'lib/src/ui/screen/word_mute_screen.dart': (
    count: 1,
    reason:
        'Misskey のワードミュート（#1290）。1 行 1 条件の語句と正規表現の並びで、'
        '文章を書く欄ではない（ソフト / ハードの 2 段で 1 つの部品を使い回す）',
  ),
};

void main() {
  /// 当てている画面。⚠ **増やす・減らすときは、`compose_text_style.dart` の
  /// 表も直す**（線引きの正本はあちら）。
  const appliedIn = {
    'lib/src/ui/screen/compose_screen.dart',
    'lib/src/ui/screen/annict_record_screen.dart',
    'lib/src/ui/screen/annict_review_screen.dart',
    'lib/src/ui/screen/templates_manage_screen.dart',
    // 行数に上限のある欄（2026-10-12 に広げた）。
    'lib/src/ui/screen/profile_edit_screen.dart',
    'lib/src/ui/screen/chat_room_edit_screen.dart',
    'lib/src/ui/widget/chat_compose_row.dart',
    // リリース前レビューで漏れていたぶん（2026-10-12）。
    'lib/src/ui/screen/collections_list_screen.dart',
    'lib/src/ui/screen/collection_detail_screen.dart',
    'lib/src/ui/screen/media_viewer_screen.dart',
    'lib/src/ui/widget/report_comment_dialog.dart',
  };

  late Map<String, String> sources;

  setUpAll(() {
    sources = {
      for (final file in sourceFiles('lib/src', skipGenerated: true))
        file.path: maskStrings(maskComments(file.readAsStringSync())),
    };
  });

  group('スタイルの組み立て', () {
    test('⚠ 設定が空なら null（テーマの既定のまま・見た目を変えない）', () {
      expect(composeTextStyleOf(''), isNull);
    });

    test('設定があれば、そのフォントを指す', () {
      expect(composeTextStyleOf('HackGen')?.fontFamily, 'HackGen');
    });
  });

  group('⚠ 走査が空振りしていない', () {
    test('lib のソースを読めている', () {
      expect(sources.length, greaterThan(200));
      for (final path in appliedIn) {
        expect(sources.keys, contains(path));
      }
    });

    test('ヘルパーの本体は設定を読んでいる', () {
      expect(
        sources['lib/src/ui/util/compose_text_style.dart'],
        contains('composeFontFamilyProvider'),
      );
    });
  });

  test('当てている画面が、表のとおり', () {
    final callers = {
      for (final entry in sources.entries)
        if (appliesComposeTextStyle(entry.value) &&
            !entry.key.endsWith('/compose_text_style.dart'))
          entry.key,
    };
    expect(callers, appliedIn);
  });

  test('⚠⚠ 高さが伸びる欄を持つ画面は、すべて当てている（当て漏れ）', () {
    // 2026-10-12: Annict の感想の欄が 2 画面あり、片方（エピソードの記録）を
    // 落としていた。「当てている画面」を数えるだけでは、当て漏れは見えない。
    final growing = {
      for (final entry in sources.entries)
        if (hasGrowingField(entry.value)) entry.key,
    };
    // ⚠ 空振りしていないこと（当てている画面のうち、伸びる欄を持つのは 4 つ）。
    expect(growing.length, greaterThanOrEqualTo(4));
    expect(
      growing.difference(appliedIn),
      isEmpty,
      reason:
          '高さが伸びる欄（maxLines: null）を持つのに composeTextStyle(ref) を'
          '当てていない画面がある。当てるか、線引きを見直すこと',
    );
  });

  // #1283: 上の 2 つはファイル単位で、行数に上限のある欄も見ていなかった。
  // v2.2 のレビューで 4 欄の漏れが出たので、欄ごとに見る。
  test('⚠⚠ 複数行の入力欄は、欄ごとに当てている（免除は理由つきの表だけ）', () {
    final offenders = <String>[];
    final counts = <String, int>{};
    var fields = 0;
    for (final entry in sources.entries) {
      fields += RegExp(
        r'\bText(?:Form)?Field\(',
      ).allMatches(entry.value).length;
      for (final line in findMultilineFieldsWithoutComposeStyle(entry.value)) {
        counts[entry.key] = (counts[entry.key] ?? 0) + 1;
        if (!_unstyledMultiline.containsKey(entry.key)) {
          offenders.add('${entry.key}:$line');
        }
      }
    }
    expect(fields, greaterThan(50), reason: '入力欄が見つからないなら、走査が壊れている');
    expect(
      offenders,
      isEmpty,
      reason:
          '複数行の入力欄に composeTextStyle(ref) が当たっていない。'
          '`style: composeTextStyle(ref)` を足し、compose_text_style.dart の表に'
          '行を足すこと。文章を書く欄でないなら、免除の表に理由を書く',
    );
    for (final entry in _unstyledMultiline.entries) {
      expect(
        counts[entry.key] ?? 0,
        entry.value.count,
        reason: '免除の表と実際の件数が合わない: ${entry.key}',
      );
    }
  });

  test('⚠ 設定を画面が直に読んで、スタイルを自前で組んでいない', () {
    // 設定を直に読んでよいのは、ヘルパー・設定の定義・設定画面だけ。
    const allowed = {
      'lib/src/ui/util/compose_text_style.dart',
      'lib/src/provider/preferences_provider.dart',
      'lib/src/ui/screen/settings/desktop_settings_screen.dart',
    };
    final offenders = [
      for (final entry in sources.entries)
        if (readsComposeFontDirectly(entry.value) &&
            !allowed.contains(entry.key))
          entry.key,
    ];
    expect(
      offenders,
      isEmpty,
      reason:
          'composeFontFamilyProvider を直に読んでいる。'
          'composeTextStyle(ref) を使うこと（次に設定が増えたときに取り残す）',
    );
    // ⚠ 許可した 3 つが実在して、実際に読んでいること（表が腐っていない）。
    for (final path in allowed) {
      expect(
        readsComposeFontDirectly(sources[path] ?? ''),
        isTrue,
        reason: '$path は設定を読んでいない。許可の表から外すこと',
      );
    }
  });

  group('⚠ 判定に合成ソースを食わせる', () {
    test('当てている形', () {
      expect(appliesComposeTextStyle('style: composeTextStyle(ref),'), isTrue);
      expect(
        appliesComposeTextStyle('final s = composeTextStyle(ref);'),
        isTrue,
      );
    });

    test('当てていない形', () {
      // 別の名前の一部。
      expect(appliesComposeTextStyle('myComposeTextStyle(ref)'), isFalse);
      // 空のとき用の関数だけを呼んでいる（設定を読まない）。
      expect(appliesComposeTextStyle("composeTextStyleOf('x')"), isFalse);
      // コメントと文字列は、潰してから渡す前提。
      expect(
        appliesComposeTextStyle(
          maskStrings(
            maskComments(
              "// composeTextStyle(ref)\nlog('composeTextStyle(ref)');",
            ),
          ),
        ),
        isFalse,
      );
    });

    test('高さが伸びる欄の形・そうでない形', () {
      expect(hasGrowingField('maxLines: null,'), isTrue);
      expect(hasGrowingField('maxLines:null'), isTrue);
      // 行数に上限のある欄。
      expect(hasGrowingField('maxLines: 5,'), isFalse);
      // 下限だけ外している（上限は別に決まる）。
      expect(hasGrowingField('minLines: null,'), isFalse);
      expect(hasGrowingField('maxLines: nullable,'), isFalse);
    });

    test('⚠⚠ 行数に上限のある欄の当て漏れが当たる（v2.2 で漏れた形）', () {
      expect(
        findMultilineFieldsWithoutComposeStyle('''
          TextField(
            controller: c,
            maxLines: 3,
            decoration: InputDecoration(labelText: x),
          );
        '''),
        [1],
      );
      // 下限だけ決めている欄・高さが伸びる欄・TextFormField。
      expect(
        findMultilineFieldsWithoutComposeStyle(
          'TextField(minLines: 2, maxLines: 6);\n'
          'TextField(maxLines: null);\n'
          'TextFormField(maxLines: 4);',
        ),
        [1, 2, 3],
      );
    });

    test('当てている欄・1 行の欄は当たらない', () {
      expect(
        findMultilineFieldsWithoutComposeStyle('''
          TextField(maxLines: 3, style: composeTextStyle(ref));
          TextField(controller: c);
          TextField(maxLines: 1);
          final bodyStyle = composeTextStyle(ref);
          TextField(maxLines: null, style: bodyStyle);
        '''),
        isEmpty,
      );
    });

    test('⚠ 別のスタイルを当てている欄は当たる（style: があるだけでは通さない）', () {
      expect(
        findMultilineFieldsWithoutComposeStyle(
          'TextField(maxLines: 3, style: theme.textTheme.bodyMedium);',
        ),
        [1],
      );
    });

    test('⚠ Text の maxLines や、子の中の maxLines は入力欄のものと数えない', () {
      expect(
        findMultilineFieldsWithoutComposeStyle('''
          Text(label, maxLines: 2);
          TextField(decoration: InputDecoration(helperMaxLines: 2, label: Text(x, maxLines: 3)));
        '''),
        isEmpty,
      );
    });

    test('設定を直に読んでいる形・いない形', () {
      expect(
        readsComposeFontDirectly('ref.watch(composeFontFamilyProvider)'),
        isTrue,
      );
      expect(
        readsComposeFontDirectly(
          'ref.read(composeFontFamilyProvider.notifier)',
        ),
        isTrue,
      );
      expect(readsComposeFontDirectly('composeTextStyle(ref)'), isFalse);
    });
  });
}

/// `composeTextStyle(` を呼んでいるか（`composeTextStyleOf(` や、別の名前の
/// 一部は数えない）。
bool appliesComposeTextStyle(String source) =>
    RegExp(r'(^|[^\w])composeTextStyle\(').hasMatch(source);

/// 高さが伸びる欄（`maxLines: null`）を持っているか。
bool hasGrowingField(String source) =>
    RegExp(r'\bmaxLines:\s*null\b').hasMatch(source);

/// [source] の中の、複数行の入力欄（`TextField` / `TextFormField`）のうち、
/// `style:` に `composeTextStyle(…)` を当てていないものの行番号 (#1283)。
///
/// 複数行と読むのは、欄の引数に `maxLines:`（`1` 以外）か `minLines:`（`1` 以外）が
/// あるもの。⚠ **入力欄の引数として拾う**ので、`Text` の `maxLines` とは混ざらない
/// （以前は字面で区別できず、行数に上限のある欄を機械で拾えなかった）。
///
/// ⚠ `style:` が変数（`style: bodyStyle`）のときは、その変数が同じファイルで
/// `composeTextStyle(` から作られていれば通す。
List<int> findMultilineFieldsWithoutComposeStyle(String source) {
  final lines = <int>[];
  for (final m in RegExp(r'\bText(?:Form)?Field\(').allMatches(source)) {
    final open = m.end - 1;
    final close = matchingCloseParen(source, open);
    if (close < 0) continue;
    final args = source.substring(open + 1, close);
    final maxLines = topLevelArgumentValue(args, 'maxLines');
    final minLines = topLevelArgumentValue(args, 'minLines');
    final multiline =
        (maxLines != null && maxLines != '1') ||
        (minLines != null && minLines != '1');
    if (!multiline) continue;
    final style = topLevelArgumentValue(args, 'style');
    if (style != null && _comesFromComposeTextStyle(style, source)) continue;
    lines.add('\n'.allMatches(source.substring(0, m.start)).length + 1);
  }
  return lines;
}

bool _comesFromComposeTextStyle(String style, String source) {
  if (appliesComposeTextStyle(style)) return true;
  if (!RegExp(r'^\w+$').hasMatch(style)) return false;
  return RegExp(
    '\\b${RegExp.escape(style)}\\s*=\\s*composeTextStyle\\(',
  ).hasMatch(source);
}

/// フォントの設定を直に読んでいるか。
bool readsComposeFontDirectly(String source) =>
    RegExp(r'\bcomposeFontFamilyProvider\b').hasMatch(source);

import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';

/// #1290: ワードミュートの編集用テキスト ↔ 一覧。本家の
/// `mute-block.word-mute.vue`（`render` / `parseMutes`）と同じ規則。
void main() {
  group('parseWordMuteText', () {
    test('半角スペース区切りはキーワードの AND、/…/ は正規表現', () {
      final result = parseWordMuteText('ダイ ポップ\n/アバン(先生)?/i\nハドラー');
      expect(result.invalidLine, isNull);
      expect(result.entries, [
        ['ダイ', 'ポップ'],
        '/アバン(先生)?/i',
        ['ハドラー'],
      ]);
    });

    test('⚠ 正規表現の行は半角スペースで分割しない', () {
      expect(parseWordMuteText('/ダイ の 大冒険/').entries, ['/ダイ の 大冒険/']);
    });

    test('⚠ 全角スペースは区切りにしない（本家と同じ）', () {
      expect(parseWordMuteText('ダイ　ポップ').entries, [
        ['ダイ　ポップ'],
      ]);
    });

    test('空行と前後の空白は捨てる・連続した空白で空の語を作らない', () {
      expect(parseWordMuteText('\n  ダイ   ポップ  \n\n').entries, [
        ['ダイ', 'ポップ'],
      ]);
    });

    test('⚠ 読めない正規表現は行番号（1 始まり・空行も数える）を返す', () {
      final result = parseWordMuteText('ダイ\n\n/(/');
      expect(result.invalidLine, 3);
    });

    test('知らないフラグの正規表現も読めない扱い', () {
      expect(parseWordMuteText('/ダイ/z').invalidLine, 1);
    });

    test('空なら空の一覧（全部消す）', () {
      expect(parseWordMuteText('  \n ').entries, isEmpty);
    });
  });

  group('formatWordMuteText', () {
    test('キーワードの組は半角スペースで繋ぎ、正規表現はそのまま', () {
      expect(
        formatWordMuteText([
          ['ダイ', 'ポップ'],
          '/アバン/i',
        ]),
        'ダイ ポップ\n/アバン/i',
      );
    });

    test('行き来しても変わらない', () {
      const entries = <Object>[
        ['ダイ', 'ポップ'],
        '/アバン/i',
        ['ハドラー'],
      ];
      expect(parseWordMuteText(formatWordMuteText(entries)).entries, entries);
    });
  });

  // #1293: テキストの形式は往復で形が変わることがある。触っていない行は変えない。
  group('⚠⚠ 触っていない行は元の要素のまま（original）', () {
    test('1 語だけの組 [/foo/] は、触らなければ正規表現に化けない', () {
      const original = <Object>[
        ['/foo/'],
      ];
      final text = formatWordMuteText(original);
      expect(text, '/foo/', reason: 'テキストでは正規表現と区別できない');
      expect(parseWordMuteText(text).entries, ['/foo/'], reason: '素の往復では化ける');
      expect(parseWordMuteText(text, original: original).entries, original);
    });

    test('⚠⚠ Dart で読めない正規表現の行があっても、触らなければ保存を止めない', () {
      // RE2 は受け付けるが、JS / Dart は名前付きグループの `(?P<…>` を読めない。
      const original = <Object>['/(?P<x>ダイ)/'];
      final text = '${formatWordMuteText(original)}\nポップ';
      expect(parseWordMuteText(text).invalidLine, 1, reason: '素では 1 行目で止まる');
      final parsed = parseWordMuteText(text, original: original);
      expect(parsed.invalidLine, isNull);
      expect(parsed.entries, [
        '/(?P<x>ダイ)/',
        ['ポップ'],
      ]);
    });

    test('書き換えた行は従来どおり検査する', () {
      const original = <Object>['/ダイ/'];
      final parsed = parseWordMuteText('/(?P<x>ダイ)/', original: original);
      expect(parsed.invalidLine, 1);
    });
  });

  group('unreadableWordMuteLines（#1293）', () {
    test('Dart で読めない正規表現の行番号だけを返す', () {
      expect(
        unreadableWordMuteLines(const [
          ['ダイ'],
          '/アバン/i',
          '/(?P<x>ダイ)/',
          '/ハドラー/z',
        ]),
        [3, 4],
      );
    });

    test('キーワードの組は対象外', () {
      expect(
        unreadableWordMuteLines(const [
          ['/(?P<x>ダイ)/'],
        ]),
        isEmpty,
      );
    });
  });
}

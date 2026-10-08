import 'package:capsicum/src/ui/util/hashtag_body.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1172: ハッシュタグの TL から投稿するときの本文。
///
/// ⚠⚠ **簡易投稿バーの送信と、そこから開く投稿フォームの初期本文が食い違っていた。**
/// バーから送るとタグが付くのに、**バーを開いてフォームにするとタグが消えた**
/// （`_openCompose` が `channelId` だけ渡していた）。⚠ 組み立てを 1 本にして、
/// 両方がこれを通るようにしてある（`simple_post_bar_compose_guard_test` が固定）。
void main() {
  group('appendHashtags', () {
    test('タグが無ければ本文そのまま', () {
      expect(appendHashtags('ほげ', const []), 'ほげ');
      expect(appendHashtags('', const []), '');
    });

    test('タグは本文の末尾・空行 1 つ挟んで空白区切り', () {
      expect(
        appendHashtags('見てます', const ['precure_fun', 'delmulin']),
        '見てます\n\n#precure_fun #delmulin',
      );
    });

    test('⚠ 本文が空でも区切りの空行は入れる（投稿の形をバーと揃える）', () {
      expect(appendHashtags('', const ['precure_fun']), '\n\n#precure_fun');
    });

    test('⚠ 渡されたタグをそのまま書く（エスケープや整形をしない）', () {
      // spec の分解は呼ぶ側（hashtagSpecTags）の責務。ここで `+` を触ると
      // `#c++` が壊れる (#1159)。
      expect(appendHashtags('x', const ['c++']), 'x\n\n#c++');
    });
  });

  group('initialComposeBody', () {
    test('⚠⚠ タグがあるときカーソルは本文の先頭', () {
      final value = initialComposeBody(null, const ['precure_fun']);

      expect(value.text, '\n\n#precure_fun');
      expect(
        value.selection.baseOffset,
        0,
        reason: '⚠ 末尾だとタグの後ろから書き始めてしまう（決定済み事項 10）',
      );
      expect(value.selection.isCollapsed, isTrue);
    });

    test('バーの入力とタグの両方があれば、入力の後ろにタグ・カーソルは先頭', () {
      final value = initialComposeBody('書きかけ', const ['delmulin']);

      expect(value.text, '書きかけ\n\n#delmulin');
      expect(value.selection.baseOffset, 0);
    });

    test('タグが無ければカーソルは末尾（従来どおり続けて書ける）', () {
      final value = initialComposeBody('書きかけ', const []);

      expect(value.text, '書きかけ');
      expect(value.selection.baseOffset, '書きかけ'.length);
    });

    test('どちらも無ければ空・カーソルは 0', () {
      final value = initialComposeBody(null, const []);

      expect(value.text, '');
      expect(value.selection.baseOffset, 0);
    });
  });
}

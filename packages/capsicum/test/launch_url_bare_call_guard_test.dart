import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/source_files.dart';

/// #1267: UI 層で外部 URL を開くときは `launchUrlOrToast` を通す。
///
/// `docs/product-policy.md` の決まりは「開けなければ SnackBar で知らせる」。
/// `launchUrlSafely` を裸で呼ぶと、開けなかった回に**何も起きない**（押しても
/// 無反応に見える）。#976 / #1221 / #1251 と 1 箇所ずつ直してきた型で、v2.1 の
/// 時点で UI 層に 18 箇所残っていた。**ここから増やさない**ためのガード。
///
/// ⚠ 残っている箇所を一度に直すことはしていない（開けなかったときに SnackBar を
/// 出してよい文脈かを 1 箇所ずつ見る必要がある）。直したら、下の表の数を減らす。

/// [source] の中の、`launchUrlSafely(` の呼び出しの数。コメントと文字列の中は
/// 数えない。
int countBareLaunchCalls(String source) => RegExp(
  r'\blaunchUrlSafely\(',
).allMatches(maskStrings(maskComments(source))).length;

/// 裸の呼び出しが残っているファイルと、その数。
///
/// ⚠⚠ **増やさない。**新しく外部 URL を開くときは `launchUrlOrToast` を使う。
/// ⚠ 数は上限ではなく**ちょうど**で見る。直して減ったら、ここも減らす
/// （減らし忘れると、そのぶん黙って増やせる余地ができる）。
const _remaining = <String, int>{
  'lib/src/ui/screen/compose_screen.dart': 1,
  'lib/src/ui/screen/eula_screen.dart': 2,
  'lib/src/ui/screen/flash_view_screen.dart': 1,
  'lib/src/ui/screen/home_screen.dart': 1,
  'lib/src/ui/screen/login_screen.dart': 1,
  'lib/src/ui/screen/media_catalog_screen.dart': 1,
  'lib/src/ui/screen/profile_screen.dart': 1,
  'lib/src/ui/screen/search_screen.dart': 2,
  'lib/src/ui/screen/server_info_screen.dart': 4,
  'lib/src/ui/util/about_dialog.dart': 1,
  'lib/src/ui/widget/content_parser.dart': 1,
  'lib/src/ui/widget/emoji_picker.dart': 1,
  'lib/src/ui/widget/home_menu.dart': 1,
};

/// `launchUrlOrToast` 自身。ここだけは `launchUrlSafely` を呼ぶのが役目。
const _implementation = 'lib/src/ui/util/launch_url_toast.dart';

void main() {
  final files = sourceFiles('lib/src/ui');

  test('走査が空振りしていない', () {
    expect(files.length, greaterThan(100));
    final paths = files.map((f) => f.path).toSet();
    expect(paths, contains(_implementation));
    for (final path in _remaining.keys) {
      expect(paths, contains(path), reason: '表のファイルが走査に入っていない: $path');
    }
    expect(
      countBareLaunchCalls(
        files.firstWhere((f) => f.path == _implementation).readAsStringSync(),
      ),
      1,
      reason: '置き換え先の中で launchUrlSafely を呼んでいる形が実在する',
    );
  });

  group('数え方', () {
    test('呼び出しを数える', () {
      expect(
        countBareLaunchCalls('''
          onPressed: () => launchUrlSafely(uri),
          onTap: () { launchUrlSafely(Uri.parse(x), mode: m); },
        '''),
        2,
      );
    });

    test('⚠ コメントと文字列の中は数えない', () {
      expect(
        countBareLaunchCalls('''
          // launchUrlSafely(uri) は使わない
          /// [launchUrlSafely] ではなく launchUrlSafely(…) の代わりに
          final s = 'launchUrlSafely(uri)';
        '''),
        0,
      );
    });

    test('⚠ 置き換え先（launchUrlOrToast）は数えない', () {
      expect(countBareLaunchCalls('launchUrlOrToast(context, uri);'), 0);
    });
  });

  test('UI 層の launchUrlSafely の裸呼び出しを、表より増やしていない', () {
    final found = <String, int>{
      for (final file in files)
        if (file.path != _implementation)
          if (countBareLaunchCalls(file.readAsStringSync()) case final n
              when n > 0)
            file.path: n,
    };
    expect(
      found,
      _remaining,
      reason:
          'UI 層では launchUrlOrToast を使う（開けなければ SnackBar で知らせる・'
          '`docs/product-policy.md`）。増えたなら置き換える。直して減ったなら、'
          'このテストの表の数を減らす (#1267)',
    );
    expect(
      found.values.fold<int>(0, (a, b) => a + b),
      18,
      reason: '残りの総数。直したぶんだけ、ここも減らす',
    );
  });
}

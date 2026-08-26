import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #1030: アプリ内のリンクのルーティングを 1 箇所に寄せたままにする。
///
/// 報告は「Play を指すプレビューカードが capsicum 内ではなく WebUI で開く」
/// だったが、本質は**カードだけがルーターを迂回していたこと**。本文・お知らせ・
/// プロフィール・チャット等の URL タップはすべて [openFediverseLink] を通り、
/// そこで自ホストの Misskey Play (#830) / fediverse の投稿・アカウント (#820) /
/// 外部サイト (#755) を出し分けている。プレビューカードだけが
/// `launchInPreferredApp` を直接呼んでいたので、**分岐を 1 つも通らずブラウザ
/// へ出て**いた。
///
/// ⚠ **1 箇所直して終わりにしない。**報告者も「リンクのルーティングは、そもそも
/// アプリ内のあらゆるリンクで同じであるべき」と書いている。次に URL を開く導線を
/// 足す人が同じ近道をしないよう、**迂回そのものを機械で止める**。
///
/// ⚠ この検査は「呼んでいないこと」を見るので、**母数が空でも緑になる**。
/// 探索が壊れていないことを別途 assert している（[allowedFiles] が実在し、
/// ルーター経由の呼び出しが十分な数見つかること）。
void main() {
  const uiRoot = 'lib/src/ui';

  /// ルーターを介さず URL を開いてよい場所。**増やすときは理由を書くこと。**
  const allowedFiles = <String>{
    // ルーター本体。ここが最終的にブラウザ / 専用アプリへ渡す出口。
    'lib/src/ui/util/fediverse_link.dart',
  };

  /// ルーターを迂回する呼び出しの形。
  const bypassCalls = <String>['launchInPreferredApp(', 'launchUrl('];

  List<File> uiDartFiles() => Directory(uiRoot)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) => !f.path.endsWith('.g.dart'))
      .where((f) => !f.path.endsWith('.freezed.dart'))
      .toList();

  /// 行コメントを落とす。doc / コメントで関数名に言及しただけの行を指摘しない。
  ///
  /// ⚠ 文字列リテラルは落とさない。`'launchUrl('` のような形で迂回する経路は
  /// 無いので、素朴に切って構わない。
  String stripLineComments(String source) => source
      .split('\n')
      .map((line) {
        final i = line.indexOf('//');
        return i == -1 ? line : line.substring(0, i);
      })
      .join('\n');

  test('探索そのものが壊れていない', () {
    final files = uiDartFiles();
    expect(
      files.length,
      greaterThan(50),
      reason: 'lib/src/ui を読めていない。パスが変わったらこの検査も直す',
    );
    for (final allowed in allowedFiles) {
      expect(
        File(allowed).existsSync(),
        isTrue,
        reason: '$allowed が無い。移動したなら allowedFiles も直す',
      );
    }
  });

  test('URL を開く導線はすべて openFediverseLink を通る (#1030)', () {
    final offenders = <String>[];
    for (final file in uiDartFiles()) {
      final path = file.path;
      if (allowedFiles.contains(path)) continue;
      final source = stripLineComments(file.readAsStringSync());
      for (final call in bypassCalls) {
        if (source.contains(call)) offenders.add('$path → $call');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'ルーターを迂回して URL を開いている。openFediverseLink(context, ref, url) '
          'に通すこと。通さないと、自ホストの Play や fediverse の投稿を指すリンクが '
          'アプリ内の画面ではなく WebUI / ブラウザで開く (#1030)',
    );
  });

  test('ルーター経由の呼び出しが実在する（検査が空振りしていない）', () {
    final callers = uiDartFiles()
        .where((f) => !allowedFiles.contains(f.path))
        .where(
          (f) => stripLineComments(
            f.readAsStringSync(),
          ).contains('openFediverseLink('),
        )
        .length;

    expect(
      callers,
      greaterThan(5),
      reason:
          'ルーター経由の導線が見つからない。全部が迂回に戻ったか、'
          '関数名が変わったのにこの検査が追随していない',
    );
  });
}

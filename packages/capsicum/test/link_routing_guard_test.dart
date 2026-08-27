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
  ///
  /// ⚠ **`launchUrlSafely(` はここに入れない。**外部サイトを開くのが正しい
  /// 導線（EULA / About / OAuth / 検索結果の外部リンク等）が 15 ファイルあり、
  /// 入れると許可リストが 15 行に膨れて陳腐化する。**「誰も
  /// `launchUrlSafely` を呼ばない」は不変条件ではない。**
  ///
  /// 守りたいのは「**ユーザー投稿の本文**を描画する経路がルーターを通ること」
  /// で、それは下の [ContentRenderer] 検査が受け持つ (#1030)。
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

  /// ⚠ **ユーザー投稿の本文を描画する経路は、必ず `onLinkTap` を渡すこと。**
  ///
  /// [ContentRenderer] は `onLinkTap` が null だと、ベタ貼り URL を
  /// `launchUrlSafely(uri)` で直接開く（`content_parser.dart` の「onLinkTap
  /// 未指定の呼び出し元では従来どおり直接開く」分岐）。つまり **渡し忘れは
  /// 例外にならず、静かにルーター迂回になる**。
  ///
  /// これは `launchUrlSafely` の呼び出し自体を数える検査では捕まらない。
  /// あちらは外部サイトを開く正当な用途が 15 ファイルあって許可リストが
  /// 陳腐化するため、**「本文を描く側が onLinkTap を渡しているか」を直接見る**。
  ///
  /// 実際、v1.61 のリリース前レビュー時点で `page_block_renderer`（Pages）と
  /// `flash_view`（Play 本文）の 2 つが渡し忘れており、**同じ Play 画面の中で
  /// サマリ側だけがルーターを通る**という割れ方をしていた。
  test('ContentRenderer は必ず onLinkTap を受け取る (#1030)', () {
    /// `ContentRenderer(` から対応する閉じ括弧までを返す。
    ///
    /// 文字列リテラル中の括弧は数えない（絵文字 URL 等に括弧が入りうる）。
    /// ⚠ **単語境界で見る。**`_wordContentRenderer(` のような**末尾一致**を
    /// 拾ってしまい、実在しない違反が 3 件出た。
    ///
    /// ⚠ **コンストラクタ宣言 (`ContentRenderer({`) は除く。**`content_parser`
    /// 自身の定義が毎回違反として出る。
    final ctor = RegExp(r'(?<![A-Za-z0-9_])ContentRenderer\((?!\{)');

    List<String> constructorArgsIn(String source) {
      final out = <String>[];
      var from = 0;
      while (true) {
        final m = ctor.firstMatch(source.substring(from));
        if (m == null) return out;
        final start = from + m.start;
        final needle = source.substring(start, from + m.end);
        var depth = 0;
        var quote = '';
        var i = start + needle.length - 1;
        final buf = StringBuffer();
        for (; i < source.length; i++) {
          final c = source[i];
          if (quote.isNotEmpty) {
            // エスケープされた次の 1 文字は引用符判定から外す。
            if (c == r'\') {
              i++;
              continue;
            }
            if (c == quote) quote = '';
            buf.write(c);
            continue;
          }
          if (c == "'" || c == '"') {
            quote = c;
            buf.write(c);
            continue;
          }
          if (c == '(') depth++;
          if (c == ')') {
            depth--;
            if (depth == 0) break;
          }
          buf.write(c);
        }
        out.add(buf.toString());
        // 閉じ括弧が見つからないまま末尾へ出たら打ち切る（`from` が
        // 長さを超えて indexOf が RangeError になる）。
        if (i >= source.length) return out;
        from = i + 1;
      }
    }

    /// 本文リンクのルーティングが要らない [ContentRenderer]。
    /// **増やすときは「他人の投稿を閲覧する経路ではない」理由を書くこと。**
    const rendererExempt = <String>{
      // 劇中ワードの候補表示 (#691)。MFM の ruby だけで、links / mentions は
      // 付かない前提（同ファイルの doc が明示）。
      'lib/src/ui/widget/emoji_picker.dart',
      // 投稿前プレビュー (`_showPreview`)。**自分がこれから出す下書き**で、
      // 他人の投稿を読む経路ではない。ここでリンクを踏んで画面遷移すると
      // 書きかけのシートを畳んでしまう。
      'lib/src/ui/screen/compose_screen.dart',
    };

    final offenders = <String>[];
    for (final file in uiDartFiles()) {
      if (rendererExempt.contains(file.path)) continue;
      final source = stripLineComments(file.readAsStringSync());
      for (final args in constructorArgsIn(source)) {
        if (!args.contains('onLinkTap:')) {
          offenders.add(file.path);
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'ContentRenderer に onLinkTap を渡していない。渡さないと本文中の URL が '
          'openFediverseLink を通らず、自ホストの投稿 / Play を指すリンクまで '
          'ブラウザで開く (#1030)',
    );
  });

  test('ContentRenderer の検査が実際にソースを読んでいる', () {
    final total = uiDartFiles()
        .where(
          (f) => stripLineComments(
            f.readAsStringSync(),
          ).contains('ContentRenderer('),
        )
        .length;

    expect(
      total,
      greaterThan(3),
      reason: 'ContentRenderer の生成が見つからない。検査が空振りしている',
    );
  });
}

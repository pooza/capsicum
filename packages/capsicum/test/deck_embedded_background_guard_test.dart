import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/source_files.dart';

/// #1250: デッキのカラムに埋め込まれる画面は、背景画像を敷かない。
///
/// ⚠ デッキはどのカラムにも背景画像を敷いていない（見せ方は #1174 で保留中）。
/// ところがタブ UI と同じ画面を `embedded: true` で使い回しているカラムは、
/// **画面が自分で背景画像を読んでいると、そのカラムだけ出てしまう**。2.0.0 では
/// スレッド（`PostDetailScreen`）がこの形だった。
///
/// 見ているのは「`embedded` を受ける画面が `backgroundImageProvider` を watch する
/// なら、その式が `embedded` で塞がれていること」。
void main() {
  List<File> embeddableScreens() => sourceFiles(
    'lib/src/ui/screen',
  ).where((f) => _acceptsEmbedded(maskComments(f.readAsStringSync()))).toList();

  test('走査が空振りしていない（埋め込める画面を拾えている）', () {
    final paths = embeddableScreens().map((f) => f.path).toList();
    // ⚠ 実数（2.0.1 時点で 11）に近い下限にする。低いと、拾う側の判定が
    // 壊れて大半が対象から落ちても緑のままになる。
    expect(paths.length, greaterThanOrEqualTo(10), reason: 'デッキに埋め込む画面の数');
    expect(
      paths,
      contains(endsWith('post_detail_screen.dart')),
      reason: '2.0.0 で背景画像が出ていた画面',
    );
    // ⚠ 「どこも読んでいない」で緑にならないこと: 対象の中に、背景画像を
    // 実際に読んでいる画面が残っている。
    expect(
      embeddableScreens().where(
        (f) =>
            _backgroundWatches(maskComments(f.readAsStringSync())).isNotEmpty,
      ),
      isNotEmpty,
      reason: '塞いだ形（embedded で分岐して読む）が実在する',
    );
  });

  test('⚠⚠ 埋め込める画面は、埋め込み時に背景画像を読まない', () {
    final offenders = <String>[];
    for (final file in embeddableScreens()) {
      offenders.addAll(
        ungatedBackgroundWatches(
          file.readAsStringSync(),
        ).map((line) => '${file.path}:$line'),
      );
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'backgroundImageProvider を watch する式に `embedded` の分岐が無い。'
          'デッキのカラムとして出たときに、そのカラムだけ背景画像が出る (#1250)',
    );
  });

  // ⚠ `embedded` を持たずにカラムへ入るもの（`NotificationView` /
  // `AnnouncementView` / `UserListView`・部品の `ui/widget`）は、上の走査の
  // 対象外 (#1238)。**埋め込みかどうかを知る手段が無い**ので、背景画像を読むこと
  // 自体を禁じる。対象は「カラムの本体（`deck_column_view.dart`）が取り込んで
  // いる画面のうち `embedded` を受けないファイル」と、部品すべて。
  test('⚠ embedded を受けずにカラムへ入るものは、背景画像を読まない', () {
    const columnView = 'lib/src/ui/widget/deck_column_view.dart';
    final imported = RegExp(r"import '\.\./screen/([a-z_]+\.dart)';")
        .allMatches(File(columnView).readAsStringSync())
        .map((m) => File('lib/src/ui/screen/${m.group(1)}'))
        .toList();
    expect(imported.length, greaterThanOrEqualTo(10), reason: '取り込みを拾えている');
    final plain = imported
        .where((f) => !_acceptsEmbedded(maskComments(f.readAsStringSync())))
        .toList();
    expect(
      plain.map((f) => f.path),
      containsAll([
        endsWith('notification_screen.dart'),
        endsWith('announcement_screen.dart'),
      ]),
      reason: 'embedded を持たずにカラムへ入る画面を拾えている',
    );
    final widgets = sourceFiles('lib/src/ui/widget');
    expect(widgets.length, greaterThanOrEqualTo(40), reason: '部品を拾えている');

    final offenders = [
      for (final file in [...plain, ...widgets])
        if (_backgroundWatches(
          maskComments(file.readAsStringSync()),
        ).isNotEmpty)
          file.path,
    ];
    expect(
      offenders,
      isEmpty,
      reason:
          '自分がカラムの中に居るかを知らないものは、背景画像を読まない。'
          '敷くのは `embedded` を見られる画面の役目 (#1250)',
    );
  });

  group('判定ロジック', () {
    test('塞いでいない watch を拾う（2.0.0 の実物の形）', () {
      const source = '''
class S extends StatefulWidget {
  final bool embedded;
}
Widget build() {
  final bgPath = storageKey != null
      ? ref.watch(backgroundImageProvider(storageKey))
      : null;
}
''';
      expect(ungatedBackgroundWatches(source), [6]);
    });

    test('embedded で塞いであれば拾わない', () {
      const source = '''
class S extends StatefulWidget {
  final bool embedded;
}
Widget build() {
  final bgPath = storageKey != null && !widget.embedded
      ? ref.watch(backgroundImageProvider(storageKey))
      : null;
}
''';
      expect(ungatedBackgroundWatches(source), isEmpty);
    });

    test('コメントの中の watch は数えない', () {
      const source = '''
class S extends StatefulWidget {
  final bool embedded;
}
// final bgPath = ref.watch(backgroundImageProvider(storageKey));
''';
      expect(ungatedBackgroundWatches(source), isEmpty);
    });

    test('別の文で embedded に触れていても、塞いだことにしない', () {
      const source = '''
class S extends StatefulWidget {
  final bool embedded;
}
Widget build() {
  final showBar = !widget.embedded;
  final bgPath = ref.watch(backgroundImageProvider(storageKey));
}
''';
      expect(ungatedBackgroundWatches(source), [6]);
    });

    // ⚠ 以前は「同じ文に `embedded` があるか」だけを見ていたので、向きが逆でも
    // 通っていた (#1238)。
    test('⚠ 逆向きの条件（埋め込み時にだけ読む）は塞いだことにしない', () {
      const source = '''
class S extends StatefulWidget {
  final bool embedded;
}
Widget build() {
  final bgPath = widget.embedded
      ? ref.watch(backgroundImageProvider(storageKey))
      : null;
}
''';
      expect(ungatedBackgroundWatches(source), [6]);
    });

    test('`embedded ? null : 読む` の形は塞いだものとして通す', () {
      const source = '''
class S extends StatefulWidget {
  final bool embedded;
}
Widget build() {
  final bgPath = widget.embedded
      ? null
      : ref.watch(backgroundImageProvider(storageKey));
}
''';
      expect(ungatedBackgroundWatches(source), isEmpty);
    });

    test('⚠ 文字列リテラルの中の embedded は塞いだことにしない', () {
      const source = '''
class S extends StatefulWidget {
  final bool embedded;
}
Widget build() {
  final bgPath = log('!embedded') != null
      ? ref.watch(backgroundImageProvider(storageKey))
      : null;
}
''';
      expect(ungatedBackgroundWatches(source), [6]);
    });
  });
}

final _embeddedField = RegExp(r'final\s+bool\s+embedded\s*;');
final _watch = RegExp(r'ref\s*\.\s*watch\s*\(\s*backgroundImageProvider\s*\(');

final _negatedEmbedded = RegExp(r'!\s*(?:widget\s*\.\s*)?embedded\b');
final _embeddedThenNull = RegExp(r'\bembedded\s*\?\s*null\s*:');

bool _acceptsEmbedded(String masked) => _embeddedField.hasMatch(masked);

Iterable<RegExpMatch> _backgroundWatches(String masked) =>
    _watch.allMatches(masked);

/// [source] の中で、`embedded` の分岐を伴わずに背景画像を watch している行番号。
///
/// 「同じ文」は、watch の位置から前へ直近の `;` / `{` / `}` までと、後ろへ直近の
/// `;` まで。その範囲に **「埋め込みでないとき」の向きの条件**が無ければ違反とする。
///
/// ⚠ 向きまで見る (#1238)。通すのは `!embedded` / `!widget.embedded`（watch より
/// 前）と、`embedded ? null : …`（埋め込みなら読まない）の 2 つの形だけ。
/// ⚠ 文字列は潰してから見る（リテラルの中の `embedded` を条件と読まない）。
List<int> ungatedBackgroundWatches(String source) {
  final masked = maskStrings(maskComments(source));
  if (!_acceptsEmbedded(masked)) return const [];
  final lines = <int>[];
  for (final match in _backgroundWatches(masked)) {
    var start = match.start;
    while (start > 0 && !';{}'.contains(masked[start - 1])) {
      start--;
    }
    var end = masked.indexOf(';', match.end);
    if (end == -1) end = masked.length;
    final before = masked.substring(start, match.start);
    final statement = masked.substring(start, end);
    final gated =
        _negatedEmbedded.hasMatch(before) ||
        _embeddedThenNull.hasMatch(statement);
    if (!gated) {
      lines.add('\n'.allMatches(masked.substring(0, match.start)).length + 1);
    }
  }
  return lines;
}

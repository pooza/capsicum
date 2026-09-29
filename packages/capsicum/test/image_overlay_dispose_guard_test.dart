import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1178: `ui.Image` の解放が leaf クラスで絞られて漏れるのを止める検査。
///
/// ## なぜ要るか
///
/// 編集画面は `ui.Image` を**ネイティブ側に**抱える。解放を忘れるとリークするが、
/// ⚠⚠ **Dart 側では何も落ちない** —— 画面は普通に動き、写真を数枚重ねて開き
/// 直した端末だけが後から落ちる（Sentry には
/// `WatchdogTermination: The OS watchdog terminated your app` として出る）。
/// 気づくのは利用者の端末が落ちたときで、**再現も特定も難しい**。
///
/// #1178 の直前まで、解放は 3 箇所すべてが
///
/// ```dart
/// if (item is _StickerOverlayItem) item.image.dispose();
/// ```
///
/// と **leaf クラスを名指し**していた。画像レイヤ (`_PictureOverlayItem`) を足す
/// ときに 1 箇所でも直し忘れると、そのぶんが黙って漏れる。そこで
/// **画像を持つ基底クラス (`_ImageBackedOverlayItem`) で絞る**形に変え、
/// 「leaf へ戻ったら落ちる」ことをここで固定する。
///
/// ⚠ これは docs/CLAUDE.md「[判定を書くときの原則] 列挙をやめ、構造で見る」の実例。
/// 「名前の表」は次に増えた名前が黙って通るが、基底クラスで絞れば
/// **派生が増えても自動で対象に入る**。
///
/// ## ⚠⚠ この形の検査は、判定が壊れても緑になる
///
/// `expect(offenders, isEmpty)` は**何も見ていなくても通る**。そのため
///
/// 1. **走査が空振りしていないこと**（解放の行が実在し、数が想定どおり）
/// 2. **判定ロジックに合成ソースを食わせる**（当たる形・当ててはいけない形）
/// 3. **穴を開けて歯を確認する**（実ファイルを leaf 名指しへ戻すと落ちる）
///
/// を同じファイルに置いてある。
void main() {
  const path = 'lib/src/ui/screen/image_overlay_screen.dart';
  late String masked;

  setUpAll(() {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '$path が見つからない');
    // ⚠ コメントと文字列リテラルを潰す。この doc 自身が
    // `is _StickerOverlayItem` を含むので、潰さないと自分を違反として数える。
    masked = maskStrings(maskComments(file.readAsStringSync()));
  });

  group('画像の解放は基底クラスで絞る (#1178)', () {
    test('leaf クラスを名指しして解放している箇所が無い', () {
      expect(
        _leafNarrowedDisposals(masked),
        isEmpty,
        reason:
            '⚠⚠ `image.dispose()` を `_StickerOverlayItem` / `_PictureOverlayItem` で'
            '絞らないこと。leaf を名指しすると、もう一方の種別のネイティブ画像が'
            '**黙って漏れる**（Dart 側では何も落ちない）。'
            '`_ImageBackedOverlayItem` で絞れば派生が増えても自動で対象に入る',
      );
    });
  });

  // ⚠ ここから下は「検査が動いていること」そのものの検査。
  group('⚠ 走査が空振りしていない', () {
    test('解放している行が実在し、基底クラスで絞られている', () {
      final guarded = _baseNarrowedDisposals(masked);
      // dispose() / _finalizeDeletion() / _restoreLayers() の 3 箇所。
      // ⚠ **数を固定する。**減ったのに緑なら、解放そのものが消えている。
      expect(
        guarded,
        hasLength(3),
        reason: '⚠⚠ 解放は 3 箇所（画面の終了・取り消しの期限切れ・復元の巻き戻し）',
      );
    });

    test('走査が `image.dispose()` を 1 つも見落としていない', () {
      // 絞り込み無しの解放（`material.image.dispose()` 等、既に型が確定している
      // もの）も含めた総数。⚠ **絞り込み付きの数を上回っていること** ——
      // 下回るなら、走査が行を取りこぼしている。
      final all = _allDisposalLines(masked);
      expect(all.length, greaterThanOrEqualTo(3));
      expect(
        all.where((line) => line.contains('_ImageBackedOverlayItem')),
        hasLength(3),
      );
    });
  });

  group('⚠ 判定ロジックに合成ソースを食わせる', () {
    test('当てるべき形', () {
      expect(
        _leafNarrowedDisposals(
          'if (item is _StickerOverlayItem) '
          'item.image.dispose();',
        ),
        isNotEmpty,
      );
      expect(
        _leafNarrowedDisposals(
          'if (item is _PictureOverlayItem) '
          'item.image.dispose();',
        ),
        isNotEmpty,
      );
      // 否定形でも同じ（`!is` で早期 return してから解放する書き方）。
      expect(
        _leafNarrowedDisposals(
          'if (item is! _StickerOverlayItem) return; '
          'item.image.dispose();',
        ),
        isNotEmpty,
      );
    });

    test('当ててはいけない形', () {
      expect(
        _leafNarrowedDisposals(
          'if (item is _ImageBackedOverlayItem) '
          'item.image.dispose();',
        ),
        isEmpty,
      );
      // 解放を伴わない leaf 判定は自由（見出し・tooltip・記述への写し取り）。
      expect(
        _leafNarrowedDisposals(
          'if (item is _StickerOverlayItem) '
          'return item.shortcode;',
        ),
        isEmpty,
      );
      // 型が確定していて絞り込みが要らない解放。
      expect(_leafNarrowedDisposals('material.image.dispose();'), isEmpty);
      // コメントと文字列リテラルは前処理で落ちる前提。
      expect(
        _leafNarrowedDisposals(
          maskStrings(
            maskComments(
              '// if (item is _StickerOverlayItem) '
              'item.image.dispose();',
            ),
          ),
        ),
        isEmpty,
      );
      expect(
        _leafNarrowedDisposals(
          maskStrings(
            maskComments(
              "log('if (item is _StickerOverlayItem) item.image.dispose();');",
            ),
          ),
        ),
        isEmpty,
      );
    });
  });

  // ⚠⚠ **これが本体の空振り検査。**マスク → 行の切り出し → 判定、の全段を通して
  // 「leaf へ戻せば落ちる」ことを見る。
  group('⚠ 歯があることを、実際に穴を開けて確かめる', () {
    test('実ファイルを leaf 名指しへ戻すと検出できる', () {
      expect(_leafNarrowedDisposals(masked), isEmpty, reason: '直す前は緑');
      final hole = masked.replaceFirst(
        '_ImageBackedOverlayItem) item.image.dispose()',
        '_StickerOverlayItem) item.image.dispose()',
      );
      expect(hole, isNot(masked), reason: '⚠⚠ 差し替え先が実在しない（書き方が変わったらこのガードも直す）');
      expect(_leafNarrowedDisposals(hole), hasLength(1));
      // 同時に、基底で絞られた数が 1 つ減ることも見る（両側から挟む）。
      expect(_baseNarrowedDisposals(hole), hasLength(2));
    });
  });
}

/// `image.dispose()` を含む行（前後の空白は落とす）。
///
/// ⚠ **文ではなく行で見る。**このリポジトリのフォーマッタ（`dart format`）は
/// `if (x) y;` を 1 行に収めるので、行で足りる。⚠ 複数行にまたがる書き方が
/// 入ったらこのガードも直すこと（[_leafNarrowedDisposals] が素通りする）。
List<String> _allDisposalLines(String masked) => [
  for (final line in masked.split('\n'))
    if (RegExp(r'\bimage\.dispose\(\)').hasMatch(line)) line.trim(),
];

/// 解放が **leaf クラス**（`_ImageBackedOverlayItem` の派生）で絞られている行。
/// 見つかれば違反。
List<String> _leafNarrowedDisposals(String masked) => [
  for (final line in _allDisposalLines(masked))
    if (_leafNarrowing.hasMatch(line)) line,
];

/// 解放が **基底クラス**で絞られている行。正しい形。
List<String> _baseNarrowedDisposals(String masked) => [
  for (final line in _allDisposalLines(masked))
    if (line.contains('_ImageBackedOverlayItem')) line,
];

/// `is` / `is!` による leaf クラスへの絞り込み。
///
/// ⚠ **`_ImageBackedOverlayItem` に当たらないこと**が肝。`_\w*OverlayItem` で
/// 雑に拾うと基底クラスも違反になり、**正しい形が永久に赤**になる。
/// ⚠ `_TextOverlayItem` は画像を持たないので、そもそも `image.dispose()` と
/// 同じ行に出ようがない（出たらコンパイルが通らない）。
final _leafNarrowing = RegExp(r'\bis!?\s+_(?:Sticker|Picture)OverlayItem\b');

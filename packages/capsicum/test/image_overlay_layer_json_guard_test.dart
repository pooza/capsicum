import 'dart:convert';
import 'dart:io';

import 'package:capsicum/src/model/image_overlay_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1130: レイヤ記述の永続化が、項目を足したときに黙って欠けるのを止める検査。
///
/// ## なぜ要るか
///
/// `OverlayLayerSpec` の 1 項目は **4 箇所が対**になっている:
///
/// | 箇所 | 役目 |
/// | --- | --- |
/// | `_specOf`（編集画面） | 画面の状態 → 記述 |
/// | `_applySpec`（編集画面） | 記述 → 画面の状態 |
/// | [OverlayLayerSpec.toJson] | 記述 → 下書き |
/// | [OverlayLayerSpec.fromJson] | 下書き → 記述 |
///
/// ⚠⚠ **片方だけ直すと「保存はされるが戻らない」になる。**しかも**壊れ方が静か**
/// で、既定値へ落ちるだけなので目視では気づきにくい（不透明度 0.4 のレイヤが
/// 1.0 で戻ってきても、言われるまで分からない）。
///
/// 往復テスト（下の group 1）だけでは足りない —— **項目を足した人がテストも
/// 更新しなければ、新しい項目は往復の対象に入らない**。そこでソースから項目名を
/// 集め、[OverlayLayerSpec.toJson] / [OverlayLayerSpec.fromJson] の両方に
/// 現れることを機械で照合する。
///
/// ## ⚠⚠ この形の検査は、判定が壊れても緑になる
///
/// `expect(offenders, isEmpty)` は**何も見ていなくても通る**（docs/CLAUDE.md
/// 「ソース検査ガードの書き方」）。そのため
///
/// 1. **走査が空振りしていないこと**を別テストで固定する（項目が拾えていること・
///    既知の名前が含まれること・本体が切り出せていること）
/// 2. **判定ロジックに合成ソースを直接食わせる**（当たるべき形と、当ててはいけない
///    形＝ローカル変数・コメント・文字列リテラル）
/// 3. **穴を開けて歯を確認する**（実ファイルへ項目を 1 つ差し込むと落ちる）
///
/// を同じファイルに置いてある。
void main() {
  final path = 'lib/src/model/image_overlay_layer.dart';
  late String masked;

  setUpAll(() {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '$path が見つからない');
    // ⚠ **コメントと文字列リテラルの両方を潰す。**doc の中の `final double nx;`
    // のような例示を項目として数えないため。
    masked = maskStrings(maskComments(file.readAsStringSync()));
  });

  group('記述の往復 (#1130)', () {
    test('文字レイヤは全項目が戻る', () {
      // ⚠ **全項目を既定値から動かす。**既定のままだと、落としても同じ値が
      // 返ってきて「戻った」ように見える。
      const spec = TextOverlayLayerSpec(
        text: 'プリキュア実況中',
        color: Color(0xFF3366CC),
        nx: 0.25,
        ny: 0.75,
        sizeFrac: 0.31,
        angle: 0.42,
        opacity: 0.6,
        visible: false,
        locked: true,
      );

      final restored = _roundTrip(spec);
      expect(restored, isA<TextOverlayLayerSpec>());
      final text = restored! as TextOverlayLayerSpec;
      expect(text.text, 'プリキュア実況中');
      expect(text.color.toARGB32(), 0xFF3366CC);
      expect(text.nx, 0.25);
      expect(text.ny, 0.75);
      expect(text.sizeFrac, 0.31);
      expect(text.angle, 0.42);
      expect(text.opacity, 0.6);
      expect(text.visible, isFalse);
      expect(text.locked, isTrue);
    });

    test('スタンプレイヤは全項目が戻る', () {
      const spec = StickerOverlayLayerSpec(
        shortcode: 'capsicum',
        url: 'https://mstdn.b-shock.org/emoji/capsicum.png',
        nx: 0.1,
        ny: 0.2,
        sizeFrac: 0.33,
        angle: -0.5,
        opacity: 0.25,
        visible: false,
        locked: true,
      );

      final restored = _roundTrip(spec);
      expect(restored, isA<StickerOverlayLayerSpec>());
      final sticker = restored! as StickerOverlayLayerSpec;
      expect(sticker.shortcode, 'capsicum');
      expect(sticker.url, 'https://mstdn.b-shock.org/emoji/capsicum.png');
      expect(sticker.nx, 0.1);
      expect(sticker.ny, 0.2);
      expect(sticker.sizeFrac, 0.33);
      expect(sticker.angle, -0.5);
      expect(sticker.opacity, 0.25);
      expect(sticker.visible, isFalse);
      expect(sticker.locked, isTrue);
    });

    test('⚠ 読めない記述は投げずに null（本文まで巻き添えにしない）', () {
      expect(OverlayLayerSpec.fromJson(null), isNull);
      expect(OverlayLayerSpec.fromJson('文字列'), isNull);
      expect(OverlayLayerSpec.fromJson(<String, Object?>{}), isNull);
      // 未知の種別（将来の版が書いたもの）。
      expect(
        OverlayLayerSpec.fromJson(<String, Object?>{
          ..._baseJson,
          'type': 'brush',
        }),
        isNull,
      );
      // 種別は既知だが固有の項目が欠けている。
      expect(
        OverlayLayerSpec.fromJson(<String, Object?>{
          ..._baseJson,
          'type': 'text',
        }),
        isNull,
      );
      // 共通項目の型が違う。
      expect(
        OverlayLayerSpec.fromJson(<String, Object?>{
          ..._baseJson,
          'type': 'sticker',
          'shortcode': 'x',
          'url': 'https://example.test/x.png',
          'visible': 'yes',
        }),
        isNull,
      );
    });

    test('整数で書かれた座標も読める（JSON は 0.0 を 0 で返しうる）', () {
      final restored = OverlayLayerSpec.fromJson(<String, Object?>{
        ..._baseJson,
        'type': 'sticker',
        'shortcode': 'x',
        'url': 'https://example.test/x.png',
        'angle': 0,
      });
      expect(restored, isNotNull);
      expect(restored!.angle, 0.0);
    });
  });

  group('項目が 4 箇所の対から落ちていない (#1130)', () {
    test('宣言した項目は toJson / fromJson の両方に現れる', () {
      expect(
        _missingFromJsonPair(masked),
        isEmpty,
        reason:
            '⚠⚠ `OverlayLayerSpec` の項目は toJson / fromJson の**両方**に要る。'
            '片方だけだと「保存はされるが戻らない」（またはその逆）になり、'
            '既定値へ静かに落ちる',
      );
    });
  });

  // ⚠ ここから下は「検査が動いていること」そのものの検査。
  group('⚠ 走査が空振りしていない', () {
    test('項目が拾えていて、既知の名前が含まれる', () {
      final fields = _specFields(masked);
      expect(
        fields,
        containsAll(<String>[
          'nx',
          'ny',
          'sizeFrac',
          'angle',
          'opacity',
          'visible',
          'locked',
          'text',
          'color',
          'shortcode',
          'url',
        ]),
        reason: '⚠⚠ ここが欠けているなら、項目の走査が本体を読めていない',
      );
      // ⚠ **同じファイルの別クラスを巻き込んでいないこと。**`ImageOverlayResult`
      // の `png` を項目として数えると、toJson に無いので恒久的に赤になる。
      expect(fields, isNot(contains('png')));
    });

    test('toJson / fromJson の本体が切り出せていて、ファイル全体ではない', () {
      final to = _toJsonBodies(masked);
      expect(to, hasLength(2), reason: '文字レイヤとスタンプレイヤの 2 つ');
      for (final body in to) {
        expect(body.length, lessThan(masked.length ~/ 4));
      }
      final from = _fromJsonBody(masked);
      expect(from, isNotNull);
      expect(from!.length, lessThan(masked.length ~/ 2));
      // ⚠ 文字列リテラルは潰れているので、識別子で掴んでいることを見る。
      expect(from, contains('StickerOverlayLayerSpec('), reason: '分岐の本体を掴んでいる');
    });

    // ⚠⚠ **これが本体の空振り検査。**マスク → 項目の走査 → 本体の切り出し →
    // 差し引き、の全段を通して「項目を 1 つ足せば落ちる」ことを見る。
    test('実ファイルへ項目を 1 つ足すと検出できる', () {
      const marker = '  final String text;';
      expect(masked, contains(marker), reason: '差し込み先が実在する');
      final hole = masked.replaceFirst(
        marker,
        '  final double slant;\n$marker',
      );
      final before = _missingFromJsonPair(masked).length;
      expect(
        _missingFromJsonPair(hole),
        hasLength(before + 1),
        reason: '⚠⚠ 増えないなら、検査は何も見ていない',
      );
      expect(_missingFromJsonPair(hole), contains('slant'));
    });

    test('片側だけ書いた項目も検出できる', () {
      // toJson には在るが fromJson に無い、という壊れ方を作る。
      final hole = masked
          .replaceFirst(
            '  final String text;',
            '  final double slant;\n  final String text;',
          )
          .replaceFirst("'text': text,", "'text': text,\n    'slant': slant,");
      expect(_missingFromJsonPair(hole), contains('slant'));
    });
  });

  group('⚠ 判定ロジックに合成ソースを食わせる', () {
    test('当てるべき形', () {
      expect(_declaredFields('  final double nx;'), contains('nx'));
      expect(
        _declaredFields('  final List<OverlayLayerSpec> layers;'),
        contains('layers'),
      );
      expect(
        _declaredFields('  final String? mimeType;'),
        contains('mimeType'),
      );
    });

    test('当ててはいけない形', () {
      // 初期化子つき＝宣言ではなくローカル / 定数。
      expect(_declaredFields('final x = 1;'), isEmpty);
      expect(_declaredFields('  final double nx = 0.5;'), isEmpty);
      // メソッドの引数や本体。
      expect(_declaredFields('void f(final int a) {}'), isEmpty);
      // コメントと文字列リテラルは前処理で落ちる前提。
      expect(
        _declaredFields(maskStrings(maskComments('// final double zz;'))),
        isEmpty,
      );
      expect(
        _declaredFields(maskStrings(maskComments("log('final double zz;');"))),
        isEmpty,
      );
    });
  });
}

/// 共通項目だけを埋めた JSON。固有項目の欠落や型違いを見る検査で使う。
const _baseJson = <String, Object?>{
  'nx': 0.5,
  'ny': 0.5,
  'sizeFrac': 0.2,
  'angle': 0.0,
  'opacity': 1.0,
  'visible': true,
  'locked': false,
};

/// ⚠ **実際に文字列化してから読み戻す。**`toJson` の戻り値をそのまま渡すと、
/// `Color` のような「JSON に載らない値」を素通りさせても気づけない。
OverlayLayerSpec? _roundTrip(OverlayLayerSpec spec) =>
    OverlayLayerSpec.fromJson(jsonDecode(jsonEncode(spec.toJson())));

/// `toJson` / `fromJson` のどちらかに現れない項目名。
List<String> _missingFromJsonPair(String masked) {
  final toJson = _toJsonBodies(masked).join('\n');
  final fromJson = _fromJsonBody(masked);
  if (fromJson == null) {
    throw StateError('fromJson の本体を切り出せていない');
  }
  return [
    for (final field in _specFields(masked))
      if (!_mentions(toJson, field) || !_mentions(fromJson, field)) field,
  ];
}

/// 記述（[OverlayLayerSpec] とその派生）が宣言している項目名。
///
/// ⚠⚠ **同じファイルに居る別のクラスを巻き込まない。**`ImageOverlayResult` は
/// 画面の戻り値で、下書きには載らない（`png` は焼き込み済みの画像そのもの）。
/// クラス名の列挙ではなく **`extends OverlayLayerSpec`** という構造で拾うので、
/// 派生が増えても自動で対象に入る。
List<String> _specFields(String masked) {
  final bodies = <String>[
    ?_bodyAfter(masked, RegExp(r'sealed\s+class\s+OverlayLayerSpec\b')),
    for (final match in RegExp(
      r'class\s+\w+\s+extends\s+OverlayLayerSpec\b',
    ).allMatches(masked))
      ?_bodyAfter(masked.substring(match.start), RegExp(r'^class\s')),
  ];
  if (bodies.isEmpty) {
    throw StateError('OverlayLayerSpec の本体を切り出せていない');
  }
  return {for (final body in bodies) ..._declaredFields(body)}.toList();
}

/// 単語境界つきの出現判定。⚠ `nx` が `_nx2` に当たらないようにする。
bool _mentions(String body, String field) =>
    RegExp('(?<![\\w\$])$field(?![\\w\$])').hasMatch(body);

/// `final <型> <名前>;`（初期化子なしの宣言）の名前。
///
/// ⚠ **初期化子があるものは除く。**`final x = 1;` はローカル変数で、記述の項目
/// ではない。型と名前の 2 語が並ぶことを求めるので、型なしの宣言にも当たらない。
List<String> _declaredFields(String masked) => RegExp(
  r'(?<![\w$])final\s+[\w<>,\s?]*[\w>?]\s+(\w+)\s*;',
).allMatches(masked).map((m) => m.group(1)!).toSet().toList();

/// 各 `toJson()` の本体（共通項目を組む `baseJson` は別枠なので含めない）。
List<String> _toJsonBodies(String masked) {
  final bodies = <String>[];
  for (final match in RegExp(
    r'Map<String, Object\?> toJson\(\)\s*=>',
  ).allMatches(masked)) {
    final open = masked.indexOf('{', match.end);
    if (open < 0) continue;
    final body = _balanced(masked, open);
    if (body != null) bodies.add(body);
  }
  // 共通項目は `baseJson` 側に書かれているので、そちらも足して 1 つの母集団に
  // する（⚠ 足さないと nx / ny が「toJson に無い」と誤検出される）。
  final base = _bodyAfter(masked, RegExp(r'baseJson\(String type\)\s*=>'));
  if (base != null) {
    return [for (final body in bodies) '$body\n$base'];
  }
  return bodies;
}

String? _fromJsonBody(String masked) =>
    _bodyAfter(masked, RegExp(r'OverlayLayerSpec\?\s+fromJson\('));

/// [pattern] の直後にある最初の `{` から、対応する `}` までを返す。
///
/// ⚠ **コメントを落とした後のソースに食わせること。**本文の `{` `}` を数えるので、
/// 日本語コメントの中の括弧を読むと本体がそこで終わったことになる。
String? _bodyAfter(String masked, Pattern pattern) {
  final match = pattern.allMatches(masked).firstOrNull;
  if (match == null) return null;
  final open = masked.indexOf('{', match.end);
  if (open < 0) return null;
  return _balanced(masked, open);
}

String? _balanced(String masked, int open) {
  var depth = 0;
  for (var i = open; i < masked.length; i++) {
    if (masked[i] == '{') depth++;
    if (masked[i] == '}') {
      depth--;
      if (depth == 0) return masked.substring(open, i + 1);
    }
  }
  return null;
}

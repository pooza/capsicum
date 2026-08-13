import 'package:capsicum/src/ui/flash/flash_result_digest.dart';
import 'package:capsicum/src/ui/flash/flash_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// #898 の判定基準を、実インベントリの変化を待たずに決定的に検証する。
///
/// 検証したい主張（#898 本文より）:
///
/// > ある Play の結果が変わる ⟺ 追加/削除/改名された絵文字が、その Play の
/// > プール構築が**走査（＝乱数消費）する集合**に入っている
///
/// 当初の計画は「絵文字が追加されるのを待って前後を突き合わせる」前向き実験
/// だったが、実在 Play の seed は `{USER_ID}{年}{月}{日}...` の形（アバンの使徒
/// スロット `9mjelnrhrj` で確認）で**日替わり**なので、seed を固定したまま
/// インベントリ変化を挟むには「同一ユーザーが同じ日のうちに、絵文字追加を
/// またいで 2 回引く」必要がある。この同日ブラケットは自然には滅多に成立せず、
/// 実際 v1.52 の計測開始から 2 週間で 1 度も発生していない。
///
/// ここでは seed を固定したままインベントリだけを差し替え、同じことを制御された
/// 条件で確かめる。自然実験より強い証拠になる（削除・改名や「挿入位置の違い」まで
/// 原因を 1 つずつ動かせるため）。
///
/// ## 走査順の前提（実測 2026-08-13・daisskey 760 件）
///
/// `/api/emojis` は **カテゴリごとのブロック構造**で返る（29 ブロック・ブロック内は
/// name 昇順）。capsicum は並べ替えずにこの順のまま `CUSTOM_EMOJIS` へ渡す
/// （`MisskeyAdapter.getEmojis` / `customEmojisProvider` とも sort しない）。
/// よって絵文字を 1 つ足すと、**そのカテゴリブロック内の name 順の位置に挿入**され、
/// それ以降の要素の乱数消費位置がすべて 1 つずれる。
///
/// ## 判定基準の精緻化（本テストで判明）
///
/// #898 本文の「交差すれば変わる」は**必要条件ではあるが十分条件ではない**。
/// プール構築は `map(@(e){random(...)})` で**要素ごとに 1 回**引くため、走査順で
/// **後ろに**入った変更は既存要素の乱数値をずらさない。よって実際の条件は:
///
/// > 出目が変わる ⟺ 変更が「走査順で、上位（`slice`）に選ばれた要素より**前**」に
/// > 入って以降の乱数対応をずらすか、変更された要素自身が上位に食い込む
///
/// この差は分類 (c)（全 `CUSTOM_EMOJIS` 走査）で顕著に出る。「どこの変更でも変わる」
/// と要約されがちだが、当選要素が先頭カテゴリ由来なら後ろのカテゴリをいくら
/// 触っても不変になる（下の 2 本がその対比）。#898 が想定した自然実験が 2 週間
/// 発火しなかったのは、この「前方でなければ効かない」性質も効いている。
void main() {
  group('Play のプール選択性 (#898)', () {
    // --- 否定側: 構造的に保証される -----------------------------------------

    // 交差しないカテゴリの変化では、対象カテゴリの走査列（要素と順序）が
    // 1 ビットも変わらないので、出目は必ず不変になる。
    test('交差しないカテゴリへの追加では出目が変わらない', () async {
      final before = await _categoryPlayDigest(_baseline);
      final after = await _categoryPlayDigest(
        _withEmoji(_baseline, name: 'aaa_newcomer', category: 'ドラクエ'),
      );

      expect(after, before);
    });

    test('交差しないカテゴリからの削除でも出目が変わらない', () async {
      final before = await _categoryPlayDigest(_baseline);
      final after = await _categoryPlayDigest(
        _baseline.where((e) => e.name != 'dq_01').toList(),
      );

      expect(after, before);
    });

    // --- 肯定側 --------------------------------------------------------------

    // 走査順の先頭に入るので、以降 7 件の乱数消費位置がすべてずれる。
    test('走査対象カテゴリの前寄りへの追加で出目が変わる', () async {
      final before = await _categoryPlayDigest(_baseline);
      final after = await _categoryPlayDigest(
        _withEmoji(_baseline, name: 'aaa_newcomer', category: _targetCategory),
      );

      expect(after, isNot(before));
    });

    test('走査対象カテゴリからの削除で出目が変わる', () async {
      final before = await _categoryPlayDigest(_baseline);
      final after = await _categoryPlayDigest(
        _baseline.where((e) => e.name != 'avan_01').toList(),
      );

      expect(after, isNot(before));
    });

    // 改名は件数を変えないので「乱数の消費回数」だけでは説明がつかない。name 順の
    // 位置が動くことで走査順が変わり、以降の対応がずれる。
    test('走査対象カテゴリ内での改名（走査順が動く）で出目が変わる', () async {
      final before = await _categoryPlayDigest(_baseline);
      final after = await _categoryPlayDigest(
        _renamed(_baseline, from: 'avan_01', to: 'zzz_avan'),
      );

      expect(after, isNot(before));
    });

    // --- 判定基準の但し書き --------------------------------------------------

    // 走査順の末尾への追加は既存要素の乱数値をずらさない。ここでは新入りが上位に
    // 食い込まなかったため出目は不変で、「交差すれば必ず変わる」が成り立たない
    // 実例になっている。交差の有無だけでなく**挿入位置**まで見ないと予測できない。
    test('走査対象カテゴリの末尾への追加では、上位に食い込まない限り変わらない', () async {
      final before = await _categoryPlayDigest(_baseline);
      final after = await _categoryPlayDigest(
        _withEmoji(_baseline, name: 'zzz_newcomer', category: _targetCategory),
      );

      expect(after, before);
    });

    // --- 分類 (c) / (d) ------------------------------------------------------

    // 全件走査 Play はカテゴリで絞らないので、どのカテゴリの変更も走査集合に
    // 交差する。前方に入れば当然のように変わる。
    test('全 CUSTOM_EMOJIS を走査する Play は走査順の前方への追加で変わる', () async {
      final before = await _wholeInventoryPlayDigest(_baseline);
      final after = await _wholeInventoryPlayDigest(
        _withEmoji(
          _baseline,
          name: 'aaa_newcomer',
          category: _categoryOrder.first,
        ),
      );

      expect(after, isNot(before));
    });

    // ただし「全件走査だからどこの変更でも変わる」は成り立たない。この fixture の
    // 当選 3 件は先頭カテゴリ由来なので、後ろのカテゴリを触っても乱数対応がずれず
    // 不変のままになる。分類 (a) の否定側が**構造的に保証される**のに対し、こちらは
    // **たまたま不変**であるという違いがある（当選要素の位置次第で結果が変わる）。
    test('全件走査 Play でも、当選要素より後ろの変更では変わらない', () async {
      final before = await _wholeInventoryPlayDigest(_baseline);
      final after = await _wholeInventoryPlayDigest(
        _withEmoji(_baseline, name: 'zzz_newcomer', category: 'ドラクエ'),
      );

      expect(after, before);
    });

    // v1.52 の計測で観測された 5 本のうち 4 本がこの分類だった。
    test('固定配列の Play はインベントリが変わっても不変', () async {
      final before = await _fixedArrayPlayDigest(_baseline);
      final after = await _fixedArrayPlayDigest(
        _withEmoji(_baseline, name: 'aaa_newcomer', category: _targetCategory),
      );

      expect(after, before);
    });

    // 同一インベントリ・同一 seed なら何度引いても同じ、が全体の前提。ここが
    // 崩れていると上の対比が意味を失う。
    test('同一インベントリ・同一 seed なら再実行しても不変', () async {
      final first = await _categoryPlayDigest(_baseline);
      final second = await _categoryPlayDigest(_baseline);

      expect(second, first);
    });
  });
}

const _targetCategory = 'アバンの使徒';

/// カテゴリブロックの並び。実サーバーの `/api/emojis` と同じ「カテゴリごとに
/// まとまり、ブロック内は name 昇順」を再現するための順序定義。
const _categoryOrder = [_targetCategory, 'キャラクター', 'ドラクエ', null];

/// 実 daisskey（760 件・アバンの使徒 82 件）の縮小版。選択性の検証には走査対象と
/// 非対象が複数あれば足りる。
final List<({String name, String? category})> _baseline = _ordered([
  for (var i = 1; i <= 8; i++)
    (name: 'avan_${i.toString().padLeft(2, '0')}', category: _targetCategory),
  for (var i = 1; i <= 5; i++)
    (name: 'chara_${i.toString().padLeft(2, '0')}', category: 'キャラクター'),
  for (var i = 1; i <= 5; i++)
    (name: 'dq_${i.toString().padLeft(2, '0')}', category: 'ドラクエ'),
  (name: 'uncategorized', category: null),
]);

/// サーバーの返却順（カテゴリブロック → ブロック内 name 昇順）へ整える。
List<({String name, String? category})> _ordered(
  List<({String name, String? category})> emojis,
) {
  final sorted = [...emojis];
  sorted.sort((a, b) {
    final ai = _categoryOrder.indexOf(a.category);
    final bi = _categoryOrder.indexOf(b.category);
    if (ai != bi) return ai.compareTo(bi);
    return a.name.compareTo(b.name);
  });
  return sorted;
}

List<({String name, String? category})> _withEmoji(
  List<({String name, String? category})> emojis, {
  required String name,
  required String? category,
}) => _ordered([...emojis, (name: name, category: category)]);

List<({String name, String? category})> _renamed(
  List<({String name, String? category})> emojis, {
  required String from,
  required String to,
}) => _ordered([
  for (final e in emojis)
    if (e.name == from) (name: to, category: e.category) else e,
]);

/// 分類 (a): 単一カテゴリで絞ってプールを組む Play。形は実在の「アバンの使徒
/// スロット」から書き写している（アニメーションは無シードの `Math:rnd` で描かれ
/// 最終的に `@result()` の出目で上書きされるため、出目には効かない。この非同期の
/// 罠自体は `flash_runtime_test.dart` が別に固定している）。
const _categoryPlayScript =
    '''
let random = Math:gen_rng(`{USER_ID}20260813_pool_test`)
let categories = ["$_targetCategory"]
let emojis = CUSTOM_EMOJIS.filter(@(e){categories.incl(e.category)}).map(@(e){[e `{random(0 100000)}`]}).sort(@(a b){Str:lt(a[1] b[1])}).slice(0 3).map(@(d){`:{d[0].name}:`})
Ui:render([
  Ui:C:mfm({ text: emojis.join(" ") }, "result")
])
''';

/// 分類 (c): 全 CUSTOM_EMOJIS を走査する Play。
const _wholeInventoryPlayScript = '''
let random = Math:gen_rng(`{USER_ID}20260813_pool_test`)
let emojis = CUSTOM_EMOJIS.map(@(e){[e `{random(0 100000)}`]}).sort(@(a b){Str:lt(a[1] b[1])}).slice(0 3).map(@(d){`:{d[0].name}:`})
Ui:render([
  Ui:C:mfm({ text: emojis.join(" ") }, "result")
])
''';

/// 分類 (d): 固定配列から選ぶ、絵文字インベントリ非依存の Play。
const _fixedArrayPlayScript = '''
let random = Math:gen_rng(`{USER_ID}20260813_pool_test`)
let choices = [":dai:" ":popp:" ":maam:" ":hyunckel:" ":leona:"]
let picked = [
  choices[random(0 choices.len-1)]
  choices[random(0 choices.len-1)]
  choices[random(0 choices.len-1)]
]
Ui:render([
  Ui:C:mfm({ text: picked.join(" ") }, "result")
])
''';

Future<String> _categoryPlayDigest(
  List<({String name, String? category})> emojis,
) => _digestOf(_categoryPlayScript, emojis);

Future<String> _wholeInventoryPlayDigest(
  List<({String name, String? category})> emojis,
) => _digestOf(_wholeInventoryPlayScript, emojis);

Future<String> _fixedArrayPlayDigest(
  List<({String name, String? category})> emojis,
) => _digestOf(_fixedArrayPlayScript, emojis);

/// seed に効く userId は固定する。ここが動くと「インベントリ以外の理由で変わった」
/// 可能性が入り、対比が成立しなくなる。
Future<String> _digestOf(
  String script,
  List<({String name, String? category})> emojis,
) async {
  final runtime = FlashRuntime(
    flashId: 'pool_test',
    host: 'misskey.example',
    customEmojis: emojis,
    userId: 'fixed-user-for-seed',
    userName: 'pooza',
    userUsername: 'pooza',
  );
  try {
    await runtime.run(script);
    return playResultDigest(runtime.rootChildren, runtime.component);
  } finally {
    runtime.dispose();
  }
}

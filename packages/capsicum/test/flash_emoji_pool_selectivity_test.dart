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
/// 条件で確かめる。自然実験より強い証拠になる（削除・改名まで原因を 1 つずつ
/// 動かせるため）。
///
/// ## 走査順の前提（実測 2026-08-13・daisskey 760 件）
///
/// `/api/emojis` は **カテゴリごとのブロック構造**で返る（29 ブロック・ブロック内は
/// name 昇順）。capsicum は並べ替えずにこの順のまま `CUSTOM_EMOJIS` へ渡す
/// （`MisskeyAdapter.getEmojis` / `customEmojisProvider` とも sort しない）。
/// よって絵文字を 1 つ足すと、**そのカテゴリブロック内の name 順の位置に挿入**され、
/// それ以降の要素の乱数消費位置がすべて 1 つずれる。
///
/// ## Play は 2 段構えで、件数そのものが効く（ここを外すと結論を誤る）
///
/// 実在の Play はプールを組んで終わりではなく、**組んだプールからさらに引く**:
///
/// ```
/// let emojis = CUSTOM_EMOJIS.filter(...).map(@(e){random(...)})...slice(0 10)  // 対象1件につき1回消費
/// let picked = [emojis[random(...)] emojis[random(...)] emojis[random(...)]]   // その続きから3回
/// ```
///
/// プール構築が**対象1件につき乱数を1回**消費するので、対象の**件数が変われば
/// 後段 3 回の乱数位置が丸ごとずれる**。つまり挿入位置に関係なく、走査対象カテゴリ
/// の増減はそのまま出目を変える。
///
/// 当初この後段を省いて「プールの上位 3 件をそのまま表示」する簡略スクリプトで
/// 検証したところ、末尾への追加が不変に見えた。これは**簡略化の副作用**であって
/// 実物の性質ではない（実物相当の 2 段構えでは末尾追加でも変わることを実測）。
/// 以降のテストは実物と同じ 2 段構えで書く。
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

    // 走査順の末尾に足しても、件数が変わることで後段 3 回の乱数位置がずれるため
    // 出目は変わる。「前寄りに入ったときだけ変わる」ではない。
    test('走査対象カテゴリの末尾への追加でも出目が変わる', () async {
      final before = await _categoryPlayDigest(_baseline);
      final after = await _categoryPlayDigest(
        _withEmoji(_baseline, name: 'zzz_newcomer', category: _targetCategory),
      );

      expect(after, isNot(before));
    });

    // --- 分類 (c) / (d) ------------------------------------------------------

    // 全件走査 Play はカテゴリで絞らないので、どのカテゴリの変更も走査集合に交差する。
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

    // 全件走査なのでどのカテゴリの増減も走査件数を動かす。末尾でも変わる。
    test('全件走査 Play は末尾カテゴリへの追加でも変わる', () async {
      final before = await _wholeInventoryPlayDigest(_baseline);
      final after = await _wholeInventoryPlayDigest(
        _withEmoji(_baseline, name: 'zzz_newcomer', category: 'ドラクエ'),
      );

      expect(after, isNot(before));
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
let emojis = CUSTOM_EMOJIS.filter(@(e){categories.incl(e.category)}).map(@(e){[e `{random(0 100000)}`]}).sort(@(a b){Str:lt(a[1] b[1])}).slice(0 10).map(@(d){`:{d[0].name}:`})
let picked = [
  emojis[random(0 emojis.len-1)]
  emojis[random(0 emojis.len-1)]
  emojis[random(0 emojis.len-1)]
]
Ui:render([
  Ui:C:mfm({ text: picked.join(" ") }, "result")
])
''';

/// 分類 (c): 全 CUSTOM_EMOJIS を走査する Play。
const _wholeInventoryPlayScript = '''
let random = Math:gen_rng(`{USER_ID}20260813_pool_test`)
let emojis = CUSTOM_EMOJIS.map(@(e){[e `{random(0 100000)}`]}).sort(@(a b){Str:lt(a[1] b[1])}).slice(0 10).map(@(d){`:{d[0].name}:`})
let picked = [
  emojis[random(0 emojis.len-1)]
  emojis[random(0 emojis.len-1)]
  emojis[random(0 emojis.len-1)]
]
Ui:render([
  Ui:C:mfm({ text: picked.join(" ") }, "result")
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

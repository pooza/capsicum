import 'as_ui.dart';

/// 指紋の連結でフィールド境界を曖昧にしないための区切り。テキストや絵文字名に
/// まず現れない制御文字を使う（`type`+`text` の連結衝突を避ける）。
const _fieldSep = '\u0001';
const _nodeEnd = '\u0003';

/// Play 実行時の絵文字インベントリの指紋 (#898)。
///
/// [hash] は「どのインベントリ版で走ったか」を表すグローバルな版マーカー。
/// **どこのカテゴリに絵文字が増えても変わる**ため、「対象集合が交差する Play
/// だけ出目が変わる」の選択性は [PlayEmojiInventoryDigest] ではなく出目側の
/// 指紋（[playResultDigest]）で見る。カテゴリ別件数 [categoryCounts] は、
/// どのスナップショットで何がどれだけ増減したかを事後に突き合わせるための材料。
class PlayEmojiInventoryDigest {
  const PlayEmojiInventoryDigest({
    required this.count,
    required this.hash,
    required this.categoryCounts,
  });

  /// 走査対象になりうる全カスタム絵文字の件数。
  final int count;

  /// (name, category) 列（capsicum が `/api/emojis` から受け取った順）の安定ハッシュ。
  final String hash;

  /// カテゴリ名 → 件数。category 無しは `(none)` に寄せる。
  final Map<String, int> categoryCounts;
}

/// 出目（描画結果）の指紋 (#898)。
///
/// text / mfm / ボタンラベル等の可視テキストと構造を rootChildren 順に走査して
/// 連結し、FNV-1a でハッシュ化する。**同じ seed・同じ走査対象集合なら安定し、
/// その Play が走査する集合が変われば変わる**ため、絵文字追加の前後で「この Play
/// の出目が変わったか」を記憶に依らず比較できる。
///
/// [lookup] は id からコンポーネントを引く関数（[FlashRuntime.component]）。
/// コンポーネントレジストリは平坦で、循環参照を作りうる（子が親を指す）ため
/// visited で保護する。
String playResultDigest(
  List<String> rootChildren,
  AsUiComponent? Function(String id) lookup,
) {
  final buf = StringBuffer();
  final visited = <String>{};

  void walk(String id) {
    // 同じ id を二度踏まない（循環・DAG 保護）。
    if (!visited.add(id)) return;
    final component = lookup(id);
    if (component == null) return;
    buf
      ..write(component.type)
      ..write(_fieldSep)
      ..write(component.hidden ? 'h' : '')
      ..write(_fieldSep)
      ..write(component.text ?? '')
      ..write(_fieldSep);
    for (final child in component.children) {
      walk(child);
    }
    buf.write(_nodeEnd);
  }

  for (final id in rootChildren) {
    walk(id);
  }
  return _fnv1a(buf.toString());
}

/// 実行時に供給した絵文字インベントリの指紋を計算する (#898)。
PlayEmojiInventoryDigest playEmojiInventoryDigest(
  List<({String name, String? category})> emojis,
) {
  final buf = StringBuffer();
  final categoryCounts = <String, int>{};
  for (final emoji in emojis) {
    buf
      ..write(emoji.name)
      ..write(_fieldSep)
      ..write(emoji.category ?? '')
      ..write(_nodeEnd);
    final category = emoji.category ?? '(none)';
    categoryCounts[category] = (categoryCounts[category] ?? 0) + 1;
  }
  return PlayEmojiInventoryDigest(
    count: emojis.length,
    hash: _fnv1a(buf.toString()),
    categoryCounts: categoryCounts,
  );
}

/// 32-bit FNV-1a → 8 桁 hex。`String.hashCode` に依らず実装固定のアルゴリズムに
/// することで、端末・ビルド・プロセスを跨いで同じ入力なら同じ値になる（Sentry
/// 上で版・出目を突き合わせる用途に安定性が要る）。
String _fnv1a(String input) {
  var hash = 0x811c9dc5;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

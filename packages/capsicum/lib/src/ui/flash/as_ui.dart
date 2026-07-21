/// Misskey Flash（UI 表記は Play）の AiScript が `Ui:` 標準ライブラリ経由で
/// 組み立てるコンポーネントツリーのモデル (#830)。
///
/// 本家の `packages/frontend/src/aiscript/ui.ts` の `AsUiComponent` に対応する。
/// 構造上の要点は **children が「子コンポーネントの id 配列」であって入れ子の
/// オブジェクトではない**こと。コンポーネントは平坦なレジストリに登録され、
/// 親は id で子を参照する。スクリプトが `Ui:get(id)` で後から任意の
/// コンポーネントを掴んで `update()` できるのはこのため。
library;

/// `Ui:C:*` が生成する 1 コンポーネント。
///
/// [props] は AiScript 側の定義オブジェクトを Dart の素の値へ落としたもの。
/// 関数値（`onClick` 等）だけは評価器の値のまま保持するため `Object?` で持ち、
/// 呼び出しは [FlashRuntime] 側が行う。
class AsUiComponent {
  AsUiComponent({
    required this.id,
    required this.type,
    Map<String, Object?>? props,
  }) : props = props ?? <String, Object?>{};

  final String id;
  final String type;
  final Map<String, Object?> props;

  bool get hidden => props['hidden'] == true;

  /// 子コンポーネントの **id** 配列。
  List<String> get children {
    final raw = props['children'];
    if (raw is! List) return const [];
    return raw.whereType<String>().toList(growable: false);
  }

  String? get text => props['text'] as String?;

  /// 本家の `update()` は **def に存在するキーだけ**を上書きする。
  /// 未指定のキーを既定値で潰さないため、丸ごと差し替えてはいけない。
  void patch(Map<String, Object?> updates) => props.addAll(updates);
}

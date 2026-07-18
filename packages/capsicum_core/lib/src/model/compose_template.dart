/// 1 アカウントあたりのテンプレート保存上限 (#767)。モロヘイヤ側
/// `ComposeTemplateContainer::MAX_COUNT` と対の値で、上限到達時の UI 文面に使う。
const composeTemplateMaxCount = 50;

/// 投稿テンプレート（定形投稿）1 件 (#767)。保存先はモロヘイヤの per-user
/// user_config（`/compose/templates`）で、`id` はサーバー採番の UUID。
///
/// 本文（[body]）は空文字も許容する（CW だけ・タグセットだけのテンプレを認める
/// モロヘイヤ側契約に合わせる）。[cw] は未設定なら null。
class ComposeTemplate {
  /// サーバー採番の UUID。
  final String id;

  /// テンプレート名（一覧・選択肢の見出し）。非空。
  final String name;

  /// 適用時に本文へ差し込む文字列。空文字を許容する。
  final String body;

  /// 適用時に CW 欄へ差し込む文字列。null なら CW なし。
  final String? cw;

  const ComposeTemplate({
    required this.id,
    required this.name,
    required this.body,
    this.cw,
  });

  factory ComposeTemplate.fromJson(Map<String, dynamic> json) {
    final cw = json['cw'] as String?;
    return ComposeTemplate(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      body: json['body'] as String? ?? '',
      // 空文字の CW は「CW なし」と同義に倒す（モロヘイヤ側も空は nil 化する）。
      cw: (cw == null || cw.isEmpty) ? null : cw,
    );
  }
}

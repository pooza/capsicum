/// 利用者が自分の投稿について切り替えられる、モロヘイヤのハンドラー 1 件 (#1398)。
///
/// `GET /mulukhiya/api/handler/list`（モロヘイヤ 5.47.0・#4195）の 1 要素。
/// サーバー全体で無効なもの・このサーバーで動かないもの・通知のハンドラーは、
/// モロヘイヤ側が返さない。
class MulukhiyaUserHandler {
  /// ハンドラーの識別子（underscore 名）。切り替えのときに送る。
  final String name;

  /// 表示用の短い名前。無ければ null（呼ぶ側は [name] で代える）。
  final String? label;

  /// 説明。無ければ null。
  final String? description;

  /// 利用者が切り替えられるか。false のものはスイッチを無効にして並べる。
  final bool toggleable;

  /// 利用者の設定で無効にしているか。⚠ [toggleable] が false なら常に false。
  final bool disabled;

  const MulukhiyaUserHandler({
    required this.name,
    this.label,
    this.description,
    required this.toggleable,
    required this.disabled,
  });

  factory MulukhiyaUserHandler.fromJson(Map<String, dynamic> json) {
    String? text(Object? v) => v is String && v.isNotEmpty ? v : null;
    return MulukhiyaUserHandler(
      name: json['name'] as String? ?? '',
      label: text(json['label']),
      description: text(json['description']),
      toggleable: json['toggleable'] == true,
      disabled: json['disabled'] == true,
    );
  }

  MulukhiyaUserHandler copyWith({bool? disabled}) => MulukhiyaUserHandler(
    name: name,
    label: label,
    description: description,
    toggleable: toggleable,
    disabled: disabled ?? this.disabled,
  );
}

/// 実況のためにモロヘイヤが付けたアイコンデコの状態 (#1409)。
///
/// `GET /mulukhiya/api/decoration/live`（モロヘイヤ 5.48.0・#4912）の応答。
/// 実況中でなければ `{"live": false}` だけが返る。
class MulukhiyaLiveDecoration {
  /// 実況中か。
  final bool live;

  /// 番組の終わりに外すデコの id。
  ///
  /// ⚠ **実況を始めたとき既に同じデコを付けていた人には返らない**（[live] は
  /// true）。利用者のデコなのでモロヘイヤは外さない ＝ capsicum も「外す」を
  /// 出さない。
  final String? id;

  /// デコの名前。分からなければ null。
  final String? name;

  /// 番組名。分からなければ null。
  final String? program;

  /// 外れる予定の時刻。分からなければ null。
  final DateTime? restoreAt;

  const MulukhiyaLiveDecoration({
    required this.live,
    this.id,
    this.name,
    this.program,
    this.restoreAt,
  });

  /// 番組の終わりを待たずに外せるか（[live] で、外す相手が分かっている）。
  bool get restorable => live && id != null;

  factory MulukhiyaLiveDecoration.fromJson(Map<String, dynamic> json) {
    String? text(Object? v) => v is String && v.isNotEmpty ? v : null;
    final restoreAt = text(json['restore_at']);
    return MulukhiyaLiveDecoration(
      live: json['live'] == true,
      id: text(json['id']),
      name: text(json['name']),
      program: text(json['program']),
      restoreAt: restoreAt == null ? null : DateTime.tryParse(restoreAt),
    );
  }
}

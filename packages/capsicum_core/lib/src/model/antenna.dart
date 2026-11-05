/// アンテナが拾う範囲 (#1052)。Misskey の `src`。
enum AntennaSource {
  /// すべての投稿。
  all('all'),

  /// ホームのタイムライン。⚠ Misskey Web は選択肢から外している。
  home('home'),

  /// 指定したユーザーだけ。
  users('users'),

  /// リストのユーザー。⚠ Misskey Web は選択肢から外している。
  list('list'),

  /// 指定したユーザーを除く。
  usersBlacklist('users_blacklist');

  const AntennaSource(this.wire);

  /// API の値。
  final String wire;

  static AntennaSource fromWire(String? value) => AntennaSource.values
      .firstWhere((s) => s.wire == value, orElse: () => AntennaSource.all);
}

/// アンテナの条件 (#1052)。作成 / 編集で送る内容でもある。
///
/// ⚠ 項目は Misskey Web の編集画面（`MkAntennaEditor.vue`）と同じに揃える。
class AntennaDraft {
  final String name;
  final AntennaSource source;

  /// [AntennaSource.list] のときのリスト。
  final String? userListId;

  /// 外側が「または」、内側が「かつ」。空なら絞らない。
  final List<List<String>> keywords;

  /// 形は [keywords] と同じ。当たったものを除く。
  final List<List<String>> excludeKeywords;

  /// [AntennaSource.users] / [AntennaSource.usersBlacklist] のときのユーザー
  /// （`@user` / `@user@host`）。
  final List<String> users;
  final bool caseSensitive;
  final bool localOnly;
  final bool excludeBots;
  final bool withReplies;
  final bool withFile;
  final bool excludeNotesInSensitiveChannel;

  const AntennaDraft({
    required this.name,
    this.source = AntennaSource.all,
    this.userListId,
    this.keywords = const [],
    this.excludeKeywords = const [],
    this.users = const [],
    this.caseSensitive = false,
    this.localOnly = false,
    this.excludeBots = false,
    this.withReplies = false,
    this.withFile = false,
    this.excludeNotesInSensitiveChannel = false,
  });
}

class Antenna {
  final String id;
  final String name;

  /// 条件 (#1052)。一覧から読んだものは全部の項目を持つ。⚠ 名前だけで作った
  /// もの（古い呼び出し）は既定の条件になるので、編集の初期値に使わない。
  final AntennaDraft? conditions;

  const Antenna({required this.id, required this.name, this.conditions});
}

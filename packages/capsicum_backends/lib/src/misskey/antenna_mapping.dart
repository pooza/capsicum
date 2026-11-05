import 'package:capsicum_core/capsicum_core.dart';

/// `antennas/list` の 1 件を [Antenna] にする (#1052)。
///
/// ⚠ 欠けている項目は既定で埋める（古い版のサーバー・フォーク）。
Antenna misskeyAntennaFromJson(Map<String, dynamic> json) {
  List<List<String>> groups(Object? value) => [
    if (value is List)
      for (final group in value)
        if (group is List) [for (final word in group) word.toString()],
  ];
  return Antenna(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    conditions: AntennaDraft(
      name: json['name'] as String? ?? '',
      source: AntennaSource.fromWire(json['src'] as String?),
      userListId: json['userListId'] as String?,
      keywords: groups(json['keywords']),
      excludeKeywords: groups(json['excludeKeywords']),
      users: [
        if (json['users'] is List)
          for (final user in json['users'] as List) user.toString(),
      ],
      caseSensitive: json['caseSensitive'] == true,
      localOnly: json['localOnly'] == true,
      excludeBots: json['excludeBots'] == true,
      withReplies: json['withReplies'] == true,
      withFile: json['withFile'] == true,
      excludeNotesInSensitiveChannel:
          json['excludeNotesInSensitiveChannel'] == true,
    ),
  );
}

/// `antennas/create` / `antennas/update` に送る内容 (#1052)。
///
/// ⚠ `create` は `keywords` / `excludeKeywords` / `users` / `caseSensitive` /
/// `withReplies` / `withFile` を必須にしているので、全部を毎回送る。
/// ⚠ リスト以外では `userListId` を null で送る（前のリストを残さない）。
Map<String, dynamic> misskeyAntennaParams(AntennaDraft draft) => {
  'name': draft.name,
  'src': draft.source.wire,
  'userListId': draft.source == AntennaSource.list ? draft.userListId : null,
  'keywords': draft.keywords,
  'excludeKeywords': draft.excludeKeywords,
  'users': draft.users,
  'caseSensitive': draft.caseSensitive,
  'localOnly': draft.localOnly,
  'excludeBots': draft.excludeBots,
  'withReplies': draft.withReplies,
  'withFile': draft.withFile,
  'excludeNotesInSensitiveChannel': draft.excludeNotesInSensitiveChannel,
};

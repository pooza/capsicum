import 'package:json_annotation/json_annotation.dart';

part 'featured_tag.g.dart';

/// Mastodon `REST::FeaturedTagSerializer` (#1075)。
///
/// ⚠ **`statuses_count` は文字列で返る**（サーバーが `.to_s` している）。
/// `last_status_at` は日付だけの ISO 8601（例 `2026-09-04`）で、null もある。
@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonFeaturedTag {
  final String id;
  final String name;
  final String? url;
  // ⚠ 文字列でも数値でも読む（本家は文字列・版やフォークで違いうる）。
  @JsonKey(fromJson: _asString)
  final String? statusesCount;
  final String? lastStatusAt;

  const MastodonFeaturedTag({
    required this.id,
    required this.name,
    this.url,
    this.statusesCount,
    this.lastStatusAt,
  });

  factory MastodonFeaturedTag.fromJson(Map<String, dynamic> json) =>
      _$MastodonFeaturedTagFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonFeaturedTagToJson(this);
}

String? _asString(Object? value) => value?.toString();

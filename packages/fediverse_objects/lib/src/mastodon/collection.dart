import 'package:json_annotation/json_annotation.dart';

part 'collection.g.dart';

/// Mastodon 4.6 `REST::CollectionSerializer` の最小マッピング (#741)。
///
/// 通知 (`added_to_collection` / `collection_update`) に同梱される対象
/// コレクション。通知描画に必要な範囲のみ持ち、`items` / `tag` 等の重い
/// ネストは取らない（未知キーは json_serializable が無視する）。
@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonCollection {
  final String id;
  final String name;
  final String? url;
  final int? itemCount;

  const MastodonCollection({
    required this.id,
    required this.name,
    this.url,
    this.itemCount,
  });

  factory MastodonCollection.fromJson(Map<String, dynamic> json) =>
      _$MastodonCollectionFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonCollectionToJson(this);
}

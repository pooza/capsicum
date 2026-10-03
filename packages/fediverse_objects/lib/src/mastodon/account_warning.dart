import 'package:json_annotation/json_annotation.dart';

part 'account_warning.g.dart';

/// Mastodon `REST::AccountWarningSerializer` の最小マッピング (#1084)。
///
/// `moderation_warning` 通知に `moderation_warning` キーで同梱される。
/// 通知描画に要る範囲のみ持ち、`target_account` / `appeal` は取らない。
@JsonSerializable(fieldRename: FieldRename.snake)
class MastodonAccountWarning {
  final String id;

  /// `none` / `disable` / `mark_statuses_as_sensitive` / `delete_statuses` /
  /// `sensitive` / `silence` / `suspend`。
  final String action;
  final String? text;

  const MastodonAccountWarning({
    required this.id,
    required this.action,
    this.text,
  });

  factory MastodonAccountWarning.fromJson(Map<String, dynamic> json) =>
      _$MastodonAccountWarningFromJson(json);

  Map<String, dynamic> toJson() => _$MastodonAccountWarningToJson(this);
}

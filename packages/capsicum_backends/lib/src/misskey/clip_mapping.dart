import 'package:capsicum_core/capsicum_core.dart';

/// `clips/list` などの 1 件を [NoteClip] にする (#1050)。
///
/// ⚠ 欠けている項目は既定で埋める（古い版のサーバー・フォーク）。
NoteClip misskeyClipFromJson(Map<String, dynamic> json) => NoteClip(
  id: json['id'] as String,
  name: json['name'] as String? ?? '',
  description: json['description'] as String?,
  isPublic: json['isPublic'] as bool? ?? false,
  userId: json['userId'] as String?,
);

/// `clips/create` / `clips/update` の引数 (#1050)。
///
/// ⚠ 説明は空なら null を送る（Web と同じく「説明なし」にする）。省くと
/// `update` では今の説明が残り、消せない。
Map<String, dynamic> misskeyClipParams(ClipDraft draft) {
  final description = draft.description?.trim();
  return {
    'name': draft.name,
    'description': (description == null || description.isEmpty)
        ? null
        : description,
    'isPublic': draft.isPublic,
  };
}

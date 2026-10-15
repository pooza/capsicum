import 'package:capsicum_core/capsicum_core.dart';

/// `api/v2/filters` の Filter を読む (#1047)。
///
/// - `filter_action` は `warn` / `hide` / `blur`。知らない値は warn
/// - 知らない `context` は読み捨てる
/// - `keywords` は index / show / create / update が返す（`rules_requested`）
ServerFilter parseMastodonFilter(Map<String, dynamic> json) => ServerFilter(
  id: json['id'].toString(),
  title: json['title'] as String? ?? '',
  contexts: {
    for (final name in (json['context'] as List? ?? const []))
      if (name is String) ?FilterContext.fromName(name),
  },
  action: switch (json['filter_action']) {
    'hide' => FilterAction.hide,
    'blur' => FilterAction.blur,
    _ => FilterAction.warn,
  },
  expiresAt: switch (json['expires_at']) {
    final String value => DateTime.tryParse(value),
    _ => null,
  },
  keywords: [
    for (final keyword in (json['keywords'] as List? ?? const []))
      if (keyword case final Map<String, dynamic> k)
        FilterKeyword(
          id: k['id']?.toString(),
          keyword: k['keyword'] as String? ?? '',
          wholeWord: k['whole_word'] as bool? ?? false,
        ),
  ],
);

/// [draft] を `POST` / `PUT /api/v2/filters` の本文にする (#1047)。
///
/// ⚠⚠ **期限は 3 通り。**キーを送らない＝変えない、空文字＝無期限（Mastodon の
/// `Expireable#expires_in=` は `present?` でなければ期限を外す）、秒数＝今からその
/// 秒数で切れる。
///
/// ⚠ キーワードは `keywords_attributes[]` にまとめる。既存は `id` 付き、新規は
/// `id` 無し、消すものは `id` と `_destroy: true`。`filters/:id/keywords` を
/// 別に叩かないのは、1 回の保存を 1 要求に収めて、途中で失敗したときに半端な
/// 状態を残さないため。
Map<String, dynamic> mastodonFilterBody(FilterDraft draft) => {
  'title': draft.title,
  'context': [for (final context in draft.contexts) context.name],
  'filter_action': draft.action.name,
  ...switch (draft.expiry) {
    KeepFilterExpiry() => const <String, dynamic>{},
    NoFilterExpiry() => const {'expires_in': ''},
    FilterExpiresIn(:final duration) => {'expires_in': duration.inSeconds},
  },
  'keywords_attributes': [
    for (final keyword in draft.keywords)
      {
        'id': ?keyword.id,
        'keyword': keyword.keyword,
        'whole_word': keyword.wholeWord,
      },
    for (final id in draft.removedKeywordIds) {'id': id, '_destroy': true},
  ],
};

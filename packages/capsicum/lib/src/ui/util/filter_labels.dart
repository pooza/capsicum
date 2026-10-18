import 'package:capsicum_core/capsicum_core.dart';

/// フィルターの表示名 (#1047)。⚠ **Mastodon 本家の日本語ロケールに揃える**
/// （`config/locales/ja.yml` の `filters.contexts`・`simple_form.ja.yml` の
/// `filters.actions`）。Web と往復する利用者が迷わないため。
String filterContextLabel(FilterContext context) => switch (context) {
  FilterContext.home => 'ホームおよびリスト',
  FilterContext.notifications => '通知',
  FilterContext.public => '公開タイムライン',
  FilterContext.thread => '会話',
  FilterContext.account => 'プロフィール',
};

/// 適用先の補足。capsicum の画面名で、どこに効くかを書く。
String filterContextHint(FilterContext context) => switch (context) {
  FilterContext.home => 'ホーム・リスト・ブックマーク・お気に入り',
  FilterContext.notifications => 'メンション・引用などの通知',
  // ⚠ DM も public に対応させている（Mastodon Web の `utils/filters.ts` と
  // 同じ・`filterContextForTimeline`）。フィルターは Mastodon だけなので表記も
  // Mastodon の「非公開の返信」(#1293)。
  FilterContext.public => 'ローカル・連合・ハッシュタグ・検索・非公開の返信',
  FilterContext.thread => '投稿の詳細',
  FilterContext.account => 'ユーザーのプロフィールの投稿',
};

String filterActionLabel(FilterAction action) => switch (action) {
  FilterAction.warn => '警告付きで隠す',
  FilterAction.hide => '完全に隠す',
  FilterAction.blur => '警告付きでメディアを非表示にする',
};

String filterActionHint(FilterAction action) => switch (action) {
  FilterAction.warn => '投稿を畳み、フィルターの名前を出す。タップで読める',
  FilterAction.hide => '一覧から消す。投稿の詳細などでは畳んで出す',
  FilterAction.blur => '本文は見せ、画像や動画だけをぼかす',
};

/// 投稿を畳んだ行に出す文言 (#1293)。
///
/// ⚠ **SNS の本来の用語に揃える**（`docs/filter-management-plan.md` 決定済み
/// 事項 4）。Mastodon は「フィルター: 名前」、Misskey は題（「ワードミュート」
/// 「ハードワードミュート」）だけ —— Misskey に「フィルター」の語は無い。
///
/// ⚠ 投稿・通知・「すべての通知」の 3 か所がここを通る。文言を直すのはここだけ。
String filterNoticeLabel(FilterVerdict verdict) => verdict.wordMute
    ? verdict.title ?? 'ワードミュート'
    : 'フィルター: ${verdict.title ?? "非表示"}';

/// フィルターの名前の上限（Mastodon の `CustomFilter` の検証と同じ）。
const kFilterTitleMaxLength = 256;

/// フィルターのキーワードの上限（Mastodon の `CustomFilterKeyword` の検証と同じ）。
const kFilterKeywordMaxLength = 512;

/// 期限の選択肢。Mastodon Web と同じ刻み（`CustomFilter::EXPIRATION_DURATIONS`）。
const filterExpiryChoices = <(String, Duration?)>[
  ('無期限', null),
  ('30 分', Duration(minutes: 30)),
  ('1 時間', Duration(hours: 1)),
  ('6 時間', Duration(hours: 6)),
  ('12 時間', Duration(hours: 12)),
  ('1 日', Duration(days: 1)),
  ('1 週間', Duration(days: 7)),
];

/// フィルターの期限の表示（一覧と編集画面で共有）。[at] は端末の時刻で渡す。
String formatFilterExpiry(DateTime at) =>
    '${at.month}/${at.day} ${at.hour}:${at.minute.toString().padLeft(2, '0')}';

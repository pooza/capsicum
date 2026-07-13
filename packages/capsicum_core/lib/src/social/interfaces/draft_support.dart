import '../../model/draft.dart';
import '../../model/post_draft.dart';

/// サーバーサイド下書きの保存・一覧・削除 (#174)。現状は Misskey のみが
/// 提供する（`notes/drafts/*`）。予約投稿（[ScheduleSupport]）と同じ Misskey
/// `NoteDraft` を源とするが、UX が別物（下書き＝任意に呼び戻して編集 / 予約＝
/// 時刻で自動投稿）のため mixin を分離し、`adapter is DraftSupport` で出し分ける。
abstract mixin class DraftSupport {
  /// 現在の compose 内容を下書きとして保存する。[PostDraft] を流用するが
  /// `scheduledAt` は無視する（予約投稿は [ScheduleSupport] の担当）。
  Future<void> saveDraft(PostDraft draft);

  /// 保存済みの下書き一覧（予約投稿を除く）。
  Future<List<Draft>> getDrafts();

  /// 下書きを削除する。
  Future<void> deleteDraft(String id);
}

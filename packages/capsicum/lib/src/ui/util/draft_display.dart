import 'package:capsicum_core/capsicum_core.dart';

/// サーバー下書き (#174) の一覧表示を中央集約するヘルパ (#963)。
///
/// 下書きは **管理画面（`/drafts`）と compose のクイックチューザ（`_DraftSheet`）の
/// 2 か所**に同じ一覧が出る。片方だけ表記を直すと「同じ下書きなのに画面によって
/// 見え方が違う」になるため、`compose_template_display.dart` と同じ形で 1 箇所へ
/// 寄せる。
///
/// ⚠ **「（本文なし）」の括弧は全角。** `/drafts`・予約投稿・テンプレートとも
/// 全角で揃えてある（テンプレート側が半角に割れていたのを #982 で寄せた）。
/// 新しい一覧を足すときもここに合わせる。

/// 一覧のタイトルに出す本文プレビュー。本文が空なら「（本文なし）」。
///
/// 改行を畳まないのは、呼び出し側が `maxLines` で 2 行まで見せているため
/// （テンプレートは 1 行なので畳んでいる）。
String draftBodyPreview(Draft draft) {
  final content = draft.content?.trim();
  return content?.isNotEmpty == true ? content! : '（本文なし）';
}

/// 一覧のサブタイトルに出す「日時 ・ 添付N件」。添付が無ければ日時だけ。
String draftSubtitle(Draft draft) {
  final dt = draft.createdAt.toLocal();
  final dateStr =
      '${dt.year}/${dt.month}/${dt.day} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';
  return draft.attachments.isNotEmpty
      ? '$dateStr ・ 添付${draft.attachments.length}件'
      : dateStr;
}

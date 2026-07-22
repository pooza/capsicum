import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';

/// 投稿テンプレート (#767) の表示・失敗文面を中央集約するヘルパ (#867)。
///
/// compose 画面のクイックチューザ（`_TemplateSheet`）と管理画面
/// （templates_manage_screen）の両方で同じプレビュー整形・エラー→文面マッピングを
/// 使う。`post_scope_display.dart` と同じく、UI 文字列を 1 箇所へ寄せて取りこぼし
/// と分岐カバレッジのズレを防ぐ。

/// テンプレート一覧のサブタイトルに出す本文プレビュー。
/// 本文が空なら「(本文なし)」、そうでなければ改行をスペースに畳んで 1 行にする。
String composeTemplateBodyPreview(ComposeTemplate template) {
  final body = template.body.trim();
  return body.isEmpty ? '(本文なし)' : body.replaceAll('\n', ' ');
}

/// テンプレート操作（作成 / 更新 / 削除）の失敗をユーザー向け文面へ変換する。
/// 想定内のクライアントエラー（409 上限 / 422 検証 / 404 競合削除）は理由の当たりを
/// 付け、それ以外（5xx・ネットワーク・非 Dio 例外）は [fallback] を返す。生の例外
/// 文字列は UI へ出さない。
String composeTemplateErrorMessage(Object error, {required String fallback}) {
  final status = error is DioException ? error.response?.statusCode : null;
  return switch (status) {
    409 => 'テンプレートの上限（$composeTemplateMaxCount 件）に達しています',
    422 => '入力内容が不正です（名前・本文の長さを確認してください）',
    404 => 'テンプレートが見つかりません（既に削除された可能性があります）',
    _ => fallback,
  };
}

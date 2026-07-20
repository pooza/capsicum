import 'user.dart';

/// Misskey の Flash（UI 表記は Play）1 本のドメインモデル。
///
/// [Page] と違い本体は **AiScript のソースコードそのもの** ([script]) で、
/// 表示するには評価器で実行し `Ui:` 標準ライブラリ由来の描画ツリーを得る
/// 必要がある。ブロック配列を持つ Page とはレンダリング経路が根本的に違う。
///
/// #73 では一覧を出して外部ブラウザに投げるだけだったため id / title /
/// summary / userName しか持たなかった。ネイティブ実行 (#830) に向けて
/// script と作者・like 状態を追加している。
class Flash {
  final String id;
  final String title;
  final String? summary;

  /// AiScript のソース。先頭の `/// @<version>` 注釈が言語バージョン宣言で、
  /// 本家は 1.0.0 未満（および宣言なし）を legacy 実行系に回している。
  ///
  /// 一覧系エンドポイント (`flash/featured` 等) でも script は返るが、
  /// 取得元によっては欠ける可能性があるため空文字を許容する。実行前に
  /// 空でないことを確認すること。
  final String script;

  /// 作者。一覧のみを扱う経路では `user` が UserLite で返る。
  final User author;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// `private` / `public`。
  final String visibility;

  final int likedCount;

  /// 認証ユーザーが like 済みか。未認証・サーバー未提供のときは false。
  final bool isLiked;

  const Flash({
    required this.id,
    required this.title,
    required this.script,
    required this.author,
    required this.createdAt,
    required this.updatedAt,
    this.summary,
    this.visibility = 'public',
    this.likedCount = 0,
    this.isLiked = false,
  });

  Flash copyWith({int? likedCount, bool? isLiked}) => Flash(
    id: id,
    title: title,
    script: script,
    author: author,
    createdAt: createdAt,
    updatedAt: updatedAt,
    summary: summary,
    visibility: visibility,
    likedCount: likedCount ?? this.likedCount,
    isLiked: isLiked ?? this.isLiked,
  );
}

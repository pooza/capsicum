import 'attachment.dart';
import 'user.dart';

/// Misskey の Page (ページ) 機能で表現される単一ページのドメインモデル。
///
/// 読み取り専用の v1 スコープのため、AiScript 変数 (`variables`) や script
/// 本体は含まない。動的ブロック対応 (#616) が必要になった時点でフィールド
/// 追加を検討する。
class Page {
  final String id;

  /// URL slug。`/@username/pages/<name>` 形式の外部リンクから引き当てる。
  final String name;

  final String title;
  final String? summary;

  /// ブロックの配列。Misskey native の `content` をそのまま保持する。
  /// 各要素は `{ type: 'section' | 'text' | 'image' | 'note' | ... , ... }`
  /// の形を取り、レンダラ側で type ごとに分岐する。
  final List<Map<String, dynamic>> content;

  final User author;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// アイキャッチ画像 (任意)。
  final Attachment? eyeCatchingImage;

  final int likedCount;

  /// 認証ユーザーが like 済みかどうか。like 対応 (#615) で参照する。
  final bool isLiked;

  const Page({
    required this.id,
    required this.name,
    required this.title,
    this.summary,
    required this.content,
    required this.author,
    required this.createdAt,
    required this.updatedAt,
    this.eyeCatchingImage,
    this.likedCount = 0,
    this.isLiked = false,
  });
}

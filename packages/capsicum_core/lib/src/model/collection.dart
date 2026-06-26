/// Mastodon 4.6 Collections (FEP-7aa9) の最小ドメインモデル。
///
/// 通知描画 (#741) で「どのコレクションか」を示すのに必要な範囲のみを持つ。
/// 一覧閲覧 / opt-out / 作成・編集などフル機能のコレクション画面は #742 / #722。
class Collection {
  final String id;
  final String name;

  /// コレクションの公開 URL（タップ遷移用。#742 の詳細画面まではブラウザ等に委譲）。
  final String? url;

  /// 収録アイテム数（分かる場合）。
  final int? itemCount;

  const Collection({
    required this.id,
    required this.name,
    this.url,
    this.itemCount,
  });
}

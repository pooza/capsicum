import '../../model/flash.dart';

/// Misskey の Flash（UI 表記は Play）サポートを宣言する mixin。
///
/// [#73](https://github.com/pooza/capsicum/issues/73) では featured 一覧を出して
/// 外部ブラウザへ投げるだけだったため [getFeaturedFlashes] しか無かった。
/// ネイティブ実行 ([#830](https://github.com/pooza/capsicum/issues/830)) には
/// 個別取得と like 操作が要る。
///
/// ⚠⚠ **一覧を返すメソッドは、ページ送りまでアダプターが持つ** (#1361)。
/// チャンネル（`ChannelManagementSupport`）と同じく、最後まで（上限のページ数
/// まで）読んで返す。1 ページの件数とカーソルの性質（いいねの一覧はいいねの ID
/// が続きの起点になる）を知っているのはアダプターなので、アプリの側で送らない。
abstract mixin class FlashSupport {
  /// サーバーが featured 扱いしている Flash 一覧（1 回で取れる上限まで）。
  ///
  /// Misskey の `POST /api/flash/featured` 相当。**認証不要**。
  ///
  /// ⚠ このエンドポイントのページングは `offset` + `limit` で、`untilId` 方式では
  /// ない。いいね 0 件の Play は返らない（#1360）。
  Future<List<Flash>> getFeaturedFlashes();

  /// 指定 ID の Flash を取得する。
  ///
  /// Misskey の `POST /api/flash/show` を `{flashId}` パラメータで叩く。
  /// **認証不要**（public な Flash であれば）。
  Future<Flash> getFlashById(String flashId);

  /// 認証ユーザー自身の Flash 一覧。**非公開 (private) も含む**。
  ///
  /// Misskey の `POST /api/flash/my` 相当。`read:flash` スコープを要求する
  /// ため、スコープ追加前に発行された既存トークンでは失敗する。呼び出し側は
  /// スコープ不足を検出して degrade できるようにしておくこと。
  Future<List<Flash>> getMyFlashes() async => const [];

  /// Flash を探す (#1351)。
  ///
  /// Misskey の `POST /api/flash/search` 相当。**認証不要**。世代の合わない
  /// Flash も混ざるので、実行前の判定は一覧と同じものを通す。
  Future<List<Flash>> searchFlashes(String text) async => const [];

  /// 自分の Flash を削除する (#1351)（`write:flash` スコープ）。
  Future<void> deleteFlash(String flashId) async {}

  /// 認証ユーザーが like 済みの Flash 一覧。
  ///
  /// Misskey の `POST /api/flash/my-likes` 相当（`read:flash-likes` スコープ）。
  /// ⚠ 応答は `{id, flash}` の組で、`id` はいいねのエントリの ID（Flash の ID
  /// ではない）。続きの起点に使うのはこちらで、アダプターの中で扱う。
  Future<List<Flash>> getLikedFlashes() async => const [];

  /// 指定 Flash を like する（`write:flash-likes` スコープ）。
  Future<void> likeFlash(String flashId) async {}

  /// 指定 Flash の like を解除する（`write:flash-likes` スコープ）。
  Future<void> unlikeFlash(String flashId) async {}
}

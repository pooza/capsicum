import '../../model/flash.dart';
import '../../model/timeline_query.dart';

/// like 履歴 1 件分のエントリ。`likeId` はライクエントリ自体の ID で、
/// `flash` がそのライクが指す Flash 本体。`/api/i/flash-likes` の payload は
/// `{id, flash}` 構造で、ここでの `id` は **ライクエントリ ID** であり
/// Flash ID とは別物（Pages の `LikedPageEntry` と同じ構造）。
typedef LikedFlashEntry = ({String likeId, Flash flash});

/// Misskey の Flash（旧 Play）サポートを宣言する mixin。
///
/// [#73](https://github.com/pooza/capsicum/issues/73) では featured 一覧を出して
/// 外部ブラウザへ投げるだけだったため [getFeaturedFlashes] しか無かった。
/// ネイティブ実行 ([#830](https://github.com/pooza/capsicum/issues/830)) には
/// 個別取得と like 操作が要る。
abstract mixin class FlashSupport {
  /// サーバーが featured 扱いしている Flash 一覧。
  ///
  /// Misskey の `POST /api/flash/featured` 相当。**認証不要**。
  ///
  /// このエンドポイントのページングは `offset` + `limit` で、Pages 等の
  /// `sinceId` / `untilId` 方式ではない。[TimelineQuery] からは limit のみ効く。
  Future<List<Flash>> getFeaturedFlashes({TimelineQuery? query});

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
  Future<List<Flash>> getMyFlashes({TimelineQuery? query}) async => const [];

  /// 認証ユーザーが like 済みの Flash 一覧。
  ///
  /// Misskey の `POST /api/flash/my-likes` 相当（`read:flash-likes` スコープ）。
  /// 戻り値は `{likeId, flash}` の組で、pagination cursor として渡すべきは
  /// Flash ID ではなくライクエントリ ID。
  Future<List<LikedFlashEntry>> getLikedFlashes({TimelineQuery? query}) async =>
      const [];

  /// 指定 Flash を like する（`write:flash-likes` スコープ）。
  Future<void> likeFlash(String flashId) async {}

  /// 指定 Flash の like を解除する（`write:flash-likes` スコープ）。
  Future<void> unlikeFlash(String flashId) async {}
}

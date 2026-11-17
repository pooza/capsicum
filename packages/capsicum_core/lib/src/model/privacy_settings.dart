/// フォロー・フォロワーの一覧を誰に見せるか（Misskey の `followingVisibility` /
/// `followersVisibility`・#1375）。
enum FollowListVisibility {
  /// 誰にでも見せる。
  public,

  /// フォロワーにだけ見せる。
  followers,

  /// 自分だけ。
  private;

  /// サーバーの値から読む。知らない値は null（項目を出さない）。
  static FollowListVisibility? fromServer(Object? value) => switch (value) {
    'public' => FollowListVisibility.public,
    'followers' => FollowListVisibility.followers,
    'private' => FollowListVisibility.private,
    _ => null,
  };

  /// サーバーへ送る値。
  String get serverValue => name;
}

/// プライバシーとつながりやすさの設定 (#1375)。
///
/// ⚠ **null は「このサーバーでは出さない」。**読めなかった・SNS に無い項目は
/// null のままにし、画面は null の項目を出さない（版の番号では分岐しない）。
/// 書くときは [PrivacySettingsSupport.updatePrivacySettings] に**変えたい項目だけ**
/// 非 null で渡す。
///
/// | 項目 | Mastodon | Misskey |
/// | --- | --- | --- |
/// | [locked] | `locked` | `isLocked` |
/// | [discoverable] | `discoverable` | `isExplorable` |
/// | [indexable] | `indexable` | — |
/// | [hideCollections] | `hide_collections` | — |
/// | [searchEngineHidden] | `noindex`（⚠ 読むだけ） | `noCrawle` |
/// | [autoAcceptFollowed] | — | `autoAcceptFollowed` |
/// | [publicReactions] | — | `publicReactions` |
/// | [followingVisibility] | — | `followingVisibility` |
/// | [followersVisibility] | — | `followersVisibility` |
/// | [hideOnlineStatus] | — | `hideOnlineStatus` |
/// | [preventAiLearning] | — | `preventAiLearning` |
/// | [requireSigninToViewContents] | — | `requireSigninToViewContents` |
///
/// 拾わないもの（#1375 の決定）: 過去の投稿へさかのぼって効く設定
/// （Misskey の `makeNotesFollowersOnlyBefore` / `makeNotesHiddenBefore`）と、
/// チャットの設定（`chatScope`）。
class PrivacySettings {
  /// フォローを承認制にする。
  final bool? locked;

  /// おすすめ・発見（ディレクトリ）に載せる。
  final bool? discoverable;

  /// 公開投稿を検索できるようにする（Mastodon）。
  final bool? indexable;

  /// フォロー・フォロワーの一覧を隠す（Mastodon）。
  final bool? hideCollections;

  /// 検索エンジンに載せない。Mastodon の `noindex` / Misskey の `noCrawle`。
  ///
  /// ⚠ Mastodon は**読めるが API で変えられない**（[searchEngineEditable] が
  /// false）。画面は状態だけ出し、Web の設定へ誘導する（#1375・上流が API を
  /// 用意するまで待つ）。
  final bool? searchEngineHidden;

  /// [searchEngineHidden] を API で変えられるか。
  final bool searchEngineEditable;

  /// フォロー中の相手からのフォローは自動で承認する（Misskey）。
  final bool? autoAcceptFollowed;

  /// リアクションを公開する（Misskey）。
  final bool? publicReactions;

  /// フォロー一覧の公開範囲（Misskey）。
  final FollowListVisibility? followingVisibility;

  /// フォロワー一覧の公開範囲（Misskey）。
  final FollowListVisibility? followersVisibility;

  /// オンライン状態を隠す（Misskey）。
  final bool? hideOnlineStatus;

  /// AI の学習を拒否する（Misskey）。
  final bool? preventAiLearning;

  /// ログインしていない人には見せない（Misskey）。
  final bool? requireSigninToViewContents;

  const PrivacySettings({
    this.locked,
    this.discoverable,
    this.indexable,
    this.hideCollections,
    this.searchEngineHidden,
    this.searchEngineEditable = false,
    this.autoAcceptFollowed,
    this.publicReactions,
    this.followingVisibility,
    this.followersVisibility,
    this.hideOnlineStatus,
    this.preventAiLearning,
    this.requireSigninToViewContents,
  });

  /// [changes] の非 null の項目だけ差し替えた写し。画面が保存の前に手元へ
  /// 先に反映する（失敗したら元に戻す）のに使う。
  PrivacySettings merge(PrivacySettings changes) => PrivacySettings(
    locked: changes.locked ?? locked,
    discoverable: changes.discoverable ?? discoverable,
    indexable: changes.indexable ?? indexable,
    hideCollections: changes.hideCollections ?? hideCollections,
    searchEngineHidden: changes.searchEngineHidden ?? searchEngineHidden,
    searchEngineEditable: searchEngineEditable,
    autoAcceptFollowed: changes.autoAcceptFollowed ?? autoAcceptFollowed,
    publicReactions: changes.publicReactions ?? publicReactions,
    followingVisibility: changes.followingVisibility ?? followingVisibility,
    followersVisibility: changes.followersVisibility ?? followersVisibility,
    hideOnlineStatus: changes.hideOnlineStatus ?? hideOnlineStatus,
    preventAiLearning: changes.preventAiLearning ?? preventAiLearning,
    requireSigninToViewContents:
        changes.requireSigninToViewContents ?? requireSigninToViewContents,
  );
}

import 'timeline_type.dart';

/// Represents any kind of tab that can appear in the home screen tab bar.
///
/// Each subclass defines a distinct tab category. Serialized to/from a
/// compact string form for SharedPreferences persistence.
sealed class TabType {
  const TabType();

  /// Serialize to a compact string for persistence.
  ///
  /// Format examples:
  /// - `timeline:home`
  /// - `list:abc123:My List`
  /// - `hashtag:precure_fun`
  /// - `hashtag:delmulin+capsicum` (AND condition)
  /// - `channel:abc123:#general`
  /// - `notifications`
  /// - `announcements`
  String toKey();

  /// 同一性だけを表す文字列 (#1091)。**表示名を含まない。**
  ///
  /// ⚠⚠ [toKey] は [ListTab] / [ChannelTab] で表示名を含むのに、`==` / `hashCode` は
  /// id しか見ていない。**[toKey] の文字列を同一性に使うと、サーバー側でリスト名を
  /// 変えた瞬間に「同じリストなのに別物」になる**（デッキのカラム列を保存すると
  /// 並び順ごと消える）。文字列を ID・永続化キー・キャッシュのスロット名に使う
  /// ときはこちらを使う。
  ///
  /// [fromKey] で読み戻せる（表示名は null になる。表示名は実行時に解決する）。
  /// [toKey] は既存の保存形式なので触らない。
  String toIdentityKey() => toKey();

  /// Deserialize from the compact string produced by [toKey].
  ///
  /// Returns null for unrecognized formats (forward-compatible).
  static TabType? fromKey(String key) {
    if (key == 'notifications') return const NotificationsTab();
    if (key == 'announcements') return const AnnouncementsTab();
    if (key == 'messages') return const MessagesTab();

    final colon = key.indexOf(':');
    if (colon < 0) return null;
    final prefix = key.substring(0, colon);
    final value = key.substring(colon + 1);
    if (value.isEmpty) return null;

    return switch (prefix) {
      'timeline' =>
        TimelineType.values
            .where((t) => t.name == value)
            .firstOrNull
            ?.let((t) => TimelineTab(t)),
      'list' => _parseListTab(value),
      'hashtag' => HashtagTab(value),
      'channel' => _parseChannelTab(value),
      'thread' => PostThreadTab(value),
      'profile' => ProfileTab(value),
      'users' => UserListTab._parse(value),
      'quotes' => QuotesTab(value),
      'achievements' => AchievementsTab(value),
      'collections' => CollectionsTab._parse(value),
      'collection' => CollectionTab(value),
      'gallery' => GalleryPostTab(value),
      'play' => FlashTab(value),
      'chat_user' => ChatUserTab(value),
      _ => null,
    };
  }

  static ListTab? _parseListTab(String value) {
    final colon = value.indexOf(':');
    if (colon < 0) return ListTab(id: value);
    return ListTab(
      id: value.substring(0, colon),
      name: value.substring(colon + 1),
    );
  }

  static ChannelTab? _parseChannelTab(String value) {
    final colon = value.indexOf(':');
    if (colon < 0) return ChannelTab(id: value);
    return ChannelTab(
      id: value.substring(0, colon),
      name: value.substring(colon + 1),
    );
  }
}

class TimelineTab extends TabType {
  final TimelineType type;
  const TimelineTab(this.type);

  @override
  String toKey() => 'timeline:${type.name}';

  @override
  bool operator ==(Object other) => other is TimelineTab && type == other.type;

  @override
  int get hashCode => type.hashCode;
}

class ListTab extends TabType {
  final String id;
  final String? name;
  const ListTab({required this.id, this.name});

  @override
  String toKey() => name != null ? 'list:$id:$name' : 'list:$id';

  @override
  String toIdentityKey() => 'list:$id';

  @override
  bool operator ==(Object other) => other is ListTab && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

class HashtagTab extends TabType {
  final String tag;
  const HashtagTab(this.tag);

  @override
  String toKey() => 'hashtag:$tag';

  @override
  bool operator ==(Object other) => other is HashtagTab && tag == other.tag;

  @override
  int get hashCode => tag.hashCode;
}

class ChannelTab extends TabType {
  final String id;
  final String? name;
  const ChannelTab({required this.id, this.name});

  @override
  String toKey() => name != null ? 'channel:$id:$name' : 'channel:$id';

  @override
  String toIdentityKey() => 'channel:$id';

  @override
  bool operator ==(Object other) => other is ChannelTab && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

class NotificationsTab extends TabType {
  const NotificationsTab();

  @override
  String toKey() => 'notifications';

  @override
  bool operator ==(Object other) => other is NotificationsTab;

  @override
  int get hashCode => runtimeType.hashCode;
}

class AnnouncementsTab extends TabType {
  const AnnouncementsTab();

  @override
  String toKey() => 'announcements';

  @override
  bool operator ==(Object other) => other is AnnouncementsTab;

  @override
  int get hashCode => runtimeType.hashCode;
}

/// Misskey の DM (chat) 一覧画面へのショートカットタブ (#439)。Mastodon
/// の DM タイムラインタブと違い、本タブはフィードを持たず、タップで
/// `ChatThreadListScreen` (`/chat`) へ push 遷移するトリガー扱い。
/// 戻ると元のタブに戻る (タブ自体はフィードを保持しない)。
///
/// 表示は ChatSupport 持ちアダプタ (Misskey) のみで意味があるため、
/// UI 側でフィルタする想定。
class MessagesTab extends TabType {
  const MessagesTab();

  @override
  String toKey() => 'messages';

  @override
  bool operator ==(Object other) => other is MessagesTab;

  @override
  int get hashCode => runtimeType.hashCode;
}

/// デッキのカラム専用の種別 (#1148 / #1150)。⚠ **タブ UI には出ない。**
///
/// デッキのカラムから開いたもの（投稿・プロフィール・一覧等）を、元のカラムの
/// 右隣に足すときに使う（`docs/deck-ui-plan.md` 決定済み事項 9）。タブ UI 側の
/// `switch` はこの型 1 つで受けられる。
///
/// ⚠ 保存するのは id だけ。id はサーバーローカルなので、中身はカラムのアカウントで
/// 取り直す。
sealed class DeckOnlyTab extends TabType {
  const DeckOnlyTab();
}

/// 投稿のスレッド (#1148)。
class PostThreadTab extends DeckOnlyTab {
  final String postId;
  const PostThreadTab(this.postId);

  @override
  String toKey() => 'thread:$postId';

  @override
  bool operator ==(Object other) =>
      other is PostThreadTab && postId == other.postId;

  @override
  int get hashCode => postId.hashCode;
}

/// ユーザーのプロフィール (#1148)。
class ProfileTab extends DeckOnlyTab {
  final String userId;
  const ProfileTab(this.userId);

  @override
  String toKey() => 'profile:$userId';

  @override
  bool operator ==(Object other) =>
      other is ProfileTab && userId == other.userId;

  @override
  int get hashCode => userId.hashCode;
}

/// ユーザー一覧の種類 (#1150)。[UserListTab.targetId] が何の id かも決まる。
enum UserListKind {
  /// フォロー中（ユーザー id）
  following,

  /// フォロワー（ユーザー id）
  followers,

  /// お気に入りした人（投稿 id）。Misskey ではリアクションした人全員
  favouritedBy,

  /// ブースト / リノートした人（投稿 id）
  rebloggedBy,

  /// その絵文字でリアクションした人（投稿 id + [UserListTab.reaction]）
  reactedBy,
}

/// ユーザー一覧 (#1150)。
class UserListTab extends DeckOnlyTab {
  final UserListKind kind;
  final String targetId;

  /// [UserListKind.reactedBy] のときの絵文字（`:name@.:` 等。`:` を含みうる）。
  final String? reaction;

  const UserListTab(this.kind, this.targetId, {this.reaction});

  @override
  String toKey() => reaction == null
      ? 'users:${kind.name}:$targetId'
      : 'users:${kind.name}:$targetId:$reaction';

  static UserListTab? _parse(String value) {
    final first = value.indexOf(':');
    if (first <= 0) return null;
    final kind = UserListKind.values.asNameMap()[value.substring(0, first)];
    if (kind == null) return null;
    final rest = value.substring(first + 1);
    // ⚠ 絵文字は `:` を含むので、2 つ目の区切り以降はまとめて絵文字として読む。
    final second = rest.indexOf(':');
    final targetId = second < 0 ? rest : rest.substring(0, second);
    if (targetId.isEmpty) return null;
    final reaction = second < 0 ? null : rest.substring(second + 1);
    return UserListTab(
      kind,
      targetId,
      reaction: reaction == null || reaction.isEmpty ? null : reaction,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UserListTab &&
      kind == other.kind &&
      targetId == other.targetId &&
      reaction == other.reaction;

  @override
  int get hashCode => Object.hash(kind, targetId, reaction);
}

/// その投稿を引用した投稿の一覧 (#1150)。
class QuotesTab extends DeckOnlyTab {
  final String postId;
  const QuotesTab(this.postId);

  @override
  String toKey() => 'quotes:$postId';

  @override
  bool operator ==(Object other) =>
      other is QuotesTab && postId == other.postId;

  @override
  int get hashCode => postId.hashCode;
}

/// 実績の一覧 (#1150)。
class AchievementsTab extends DeckOnlyTab {
  final String userId;
  const AchievementsTab(this.userId);

  @override
  String toKey() => 'achievements:$userId';

  @override
  bool operator ==(Object other) =>
      other is AchievementsTab && userId == other.userId;

  @override
  int get hashCode => userId.hashCode;
}

/// コレクション一覧の出し方 (#1150)。
enum CollectionsMode {
  /// そのユーザーのコレクション
  list,

  /// 自分のコレクション（作成・編集できる）
  own,

  /// そのユーザーが載っているコレクション
  included,
}

/// コレクションの一覧 (#1150)。
class CollectionsTab extends DeckOnlyTab {
  final String accountId;
  final CollectionsMode mode;
  const CollectionsTab(this.accountId, this.mode);

  @override
  String toKey() => 'collections:${mode.name}:$accountId';

  static CollectionsTab? _parse(String value) {
    final colon = value.indexOf(':');
    if (colon <= 0) return null;
    final mode = CollectionsMode.values.asNameMap()[value.substring(0, colon)];
    final accountId = value.substring(colon + 1);
    if (mode == null || accountId.isEmpty) return null;
    return CollectionsTab(accountId, mode);
  }

  @override
  bool operator ==(Object other) =>
      other is CollectionsTab &&
      accountId == other.accountId &&
      mode == other.mode;

  @override
  int get hashCode => Object.hash(accountId, mode);
}

/// コレクション 1 つ (#1150)。
class CollectionTab extends DeckOnlyTab {
  final String collectionId;
  const CollectionTab(this.collectionId);

  @override
  String toKey() => 'collection:$collectionId';

  @override
  bool operator ==(Object other) =>
      other is CollectionTab && collectionId == other.collectionId;

  @override
  int get hashCode => collectionId.hashCode;
}

/// ギャラリーの投稿 1 つ (#1150)。
class GalleryPostTab extends DeckOnlyTab {
  final String postId;
  const GalleryPostTab(this.postId);

  @override
  String toKey() => 'gallery:$postId';

  @override
  bool operator ==(Object other) =>
      other is GalleryPostTab && postId == other.postId;

  @override
  int get hashCode => postId.hashCode;
}

/// Misskey Play 1 つ (#1150)。
class FlashTab extends DeckOnlyTab {
  final String flashId;
  const FlashTab(this.flashId);

  @override
  String toKey() => 'play:$flashId';

  @override
  bool operator ==(Object other) =>
      other is FlashTab && flashId == other.flashId;

  @override
  int get hashCode => flashId.hashCode;
}

/// ユーザーとのメッセージ（Misskey chat）(#1150)。
class ChatUserTab extends DeckOnlyTab {
  final String userId;
  const ChatUserTab(this.userId);

  @override
  String toKey() => 'chat_user:$userId';

  @override
  bool operator ==(Object other) =>
      other is ChatUserTab && userId == other.userId;

  @override
  int get hashCode => userId.hashCode;
}

/// Extension to enable functional-style usage with nullable values.
extension _NullableLet<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

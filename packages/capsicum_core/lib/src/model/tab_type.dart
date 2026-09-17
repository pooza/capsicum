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

/// 投稿のスレッド (#1148)。⚠ **デッキのカラム専用で、タブ UI には出ない。**
///
/// デッキのカラムから投稿を開いたとき、元のカラムの右隣に足す。保存するのは
/// id だけで、投稿そのものはカラムのアカウントで取り直す（id はサーバーローカル
/// なので、アカウントと組でないと意味を持たない）。
class PostThreadTab extends TabType {
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

/// ユーザーのプロフィール (#1148)。⚠ **デッキのカラム専用で、タブ UI には出ない。**
/// [PostThreadTab] と同じく id だけを保存する。
class ProfileTab extends TabType {
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

/// Extension to enable functional-style usage with nullable values.
extension _NullableLet<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

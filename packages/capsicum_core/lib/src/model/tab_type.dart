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
  /// - `notifications`
  /// - `announcements`
  String toKey();

  /// Deserialize from the compact string produced by [toKey].
  ///
  /// Returns null for unrecognized formats (forward-compatible).
  static TabType? fromKey(String key) {
    if (key == 'notifications') return const NotificationsTab();
    if (key == 'announcements') return const AnnouncementsTab();

    final colon = key.indexOf(':');
    if (colon < 0) return null;
    final prefix = key.substring(0, colon);
    final value = key.substring(colon + 1);
    if (value.isEmpty) return null;

    return switch (prefix) {
      'timeline' => TimelineType.values
          .where((t) => t.name == value)
          .firstOrNull
          ?.let((t) => TimelineTab(t)),
      'list' => _parseListTab(value),
      'hashtag' => HashtagTab(value),
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
}

class TimelineTab extends TabType {
  final TimelineType type;
  const TimelineTab(this.type);

  @override
  String toKey() => 'timeline:${type.name}';

  @override
  bool operator ==(Object other) =>
      other is TimelineTab && type == other.type;

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
  bool operator ==(Object other) =>
      other is ListTab && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

class HashtagTab extends TabType {
  final String tag;
  const HashtagTab(this.tag);

  @override
  String toKey() => 'hashtag:$tag';

  @override
  bool operator ==(Object other) =>
      other is HashtagTab && tag == other.tag;

  @override
  int get hashCode => tag.hashCode;
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

/// Extension to enable functional-style usage with nullable values.
extension _NullableLet<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

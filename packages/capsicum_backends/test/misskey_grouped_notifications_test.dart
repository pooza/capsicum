import 'package:capsicum_backends/src/misskey/extensions.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// #1048: `i/notifications-grouped` の `reaction:grouped` / `renote:grouped`。
///
/// ⚠⚠ **この 2 つの type では `user` が来ない**（`reactions[].user` / `users[]` に
/// 移る）。素通しすると見出しがアイコンも名前も無い 1 行になる。
void main() {
  Map<String, dynamic> user(String id, {String? name}) => {
    'id': id,
    'username': 'u$id',
    'name': name ?? 'user $id',
    'host': null,
  };

  Map<String, dynamic> note(String id, {String text = 'ばんぐみ実況'}) => {
    'id': id,
    'createdAt': '2026-09-27T00:00:00.000Z',
    'text': text,
    'userId': '99',
    'user': user('99'),
    'visibility': 'public',
    'renoteCount': 0,
    'repliesCount': 0,
  };

  Notification convert(Map<String, dynamic> json) =>
      MisskeyNotification.fromJson(json).toCapsicum('misskey.example');

  test('reaction:grouped は代表を reactions[].user から取る', () {
    final n = convert({
      'id': 'n9',
      'type': 'reaction:grouped',
      'createdAt': '2026-09-27T01:02:03.000Z',
      'note': note('500'),
      'reactions': [
        {'user': user('1', name: 'あかね'), 'reaction': ':kawaii:'},
        {'user': user('2', name: 'あおい'), 'reaction': '👍'},
      ],
    });
    expect(
      n.type,
      NotificationType.reaction,
      reason: '⚠ :grouped 付きの名前を型マップへ足さない（excludeTypes で 400 になる）',
    );
    expect(n.user?.displayName, 'あかね');
    expect(n.sampleUsers.map((u) => u.displayName), ['あかね', 'あおい']);
    expect(n.groupCount, 2);
    expect(n.groupKey, 'n9');
    expect(n.reaction, ':kawaii:', reason: '行頭に出せるのは 1 つだけなので、最も新しい 1 件');
    expect(n.post?.content, 'ばんぐみ実況');
  });

  test('renote:grouped は代表を users[] から取る', () {
    final n = convert({
      'id': 'n10',
      'type': 'renote:grouped',
      'createdAt': '2026-09-27T01:02:03.000Z',
      'note': note('501'),
      'users': [user('1', name: 'あかね'), user('2'), user('3')],
    });
    expect(n.type, NotificationType.reblog);
    expect(n.user?.displayName, 'あかね');
    expect(n.groupCount, 3);
    expect(n.reaction, isNull);
  });

  test('束ねていない通知は従来どおり（groupCount 1・groupKey なし）', () {
    final n = convert({
      'id': 'n11',
      'type': 'reaction',
      'createdAt': '2026-09-27T01:02:03.000Z',
      'user': user('1', name: 'あかね'),
      'note': note('502'),
      'reaction': '👍',
    });
    expect(n.groupCount, 1);
    expect(n.groupKey, isNull);
    expect(n.sampleUsers, isEmpty);
    expect(n.user?.displayName, 'あかね');
    expect(n.reaction, '👍');
  });

  test('未知の :grouped も元の名前で読める形に倒す', () {
    final n = convert({
      'id': 'n12',
      'type': 'follow:grouped',
      'createdAt': '2026-09-27T01:02:03.000Z',
    });
    expect(
      n.type,
      NotificationType.other,
      reason: '知らない :grouped は other。代表が無いので groupCount は 1',
    );
    expect(n.groupCount, 1);
  });
}

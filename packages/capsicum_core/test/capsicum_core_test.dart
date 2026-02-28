import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';

void main() {
  group('PostScope', () {
    test('has expected values', () {
      expect(PostScope.values, hasLength(4));
      expect(PostScope.values, contains(PostScope.public));
      expect(PostScope.values, contains(PostScope.direct));
    });
  });

  group('TimelineType', () {
    test('has expected values', () {
      expect(TimelineType.values, hasLength(4));
      expect(TimelineType.values, contains(TimelineType.home));
      expect(TimelineType.values, contains(TimelineType.federated));
    });
  });

  group('User', () {
    test('can be constructed', () {
      const user = User(id: '1', username: 'test');
      expect(user.id, '1');
      expect(user.username, 'test');
      expect(user.displayName, isNull);
    });
  });

  group('Post', () {
    test('can be constructed', () {
      final post = Post(
        id: '1',
        postedAt: DateTime(2026),
        author: const User(id: '1', username: 'test'),
        content: 'Hello, world!',
      );
      expect(post.id, '1');
      expect(post.content, 'Hello, world!');
      expect(post.scope, PostScope.public);
      expect(post.attachments, isEmpty);
    });
  });
}

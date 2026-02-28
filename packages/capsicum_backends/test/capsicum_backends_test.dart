import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';

void main() {
  group('BackendType', () {
    test('has mastodon and misskey', () {
      expect(BackendType.values, hasLength(2));
      expect(BackendType.values, contains(BackendType.mastodon));
      expect(BackendType.values, contains(BackendType.misskey));
    });
  });

  group('MastodonAdapter', () {
    test('can be created', () async {
      final adapter = await MastodonAdapter.create('mastodon.social');
      expect(adapter.host, 'mastodon.social');
      expect(adapter.capabilities.supportedScopes, contains(PostScope.public));
      expect(adapter, isA<FavoriteSupport>());
      expect(adapter, isA<BookmarkSupport>());
      expect(adapter, isA<LoginSupport>());
    });
  });

  group('MisskeyAdapter', () {
    test('can be created', () async {
      final adapter = await MisskeyAdapter.create('misskey.io');
      expect(adapter.host, 'misskey.io');
      expect(
        adapter.capabilities.supportedFormattings,
        contains(Formatting.mfm),
      );
      expect(adapter, isA<ReactionSupport>());
      expect(adapter, isA<LoginSupport>());
    });
  });
}

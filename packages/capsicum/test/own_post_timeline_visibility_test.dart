import 'package:capsicum/src/provider/timeline_provider.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #814: 楽観挿入 ([TimelineNotifier.insertOwnPost]) のゲート
/// [ownPostAppearsInTimeline] が、表示中の TL 種別 × 投稿の公開範囲で
/// 「実際にその TL に載る投稿」だけを通すことを検証する。
///
/// ここが緩むと、ローカル/連合 TL を見ているときの unlisted・フォロワー限定
/// 投稿が先頭に差し込まれ、リフレッシュで消える幻の投稿になる（#717 の後続）。
void main() {
  const user = User(id: 'u1', username: 'alice');

  Post post(PostScope scope, {bool localOnly = false}) => Post(
    id: '1',
    postedAt: DateTime(2026, 7, 6),
    author: user,
    content: 'hi',
    scope: scope,
    localOnly: localOnly,
  );

  group('ownPostAppearsInTimeline — home / social は direct 以外すべて載る', () {
    for (final type in [TimelineType.home, TimelineType.social]) {
      test('$type: public / unlisted / followersOnly は載る', () {
        expect(ownPostAppearsInTimeline(type, post(PostScope.public)), isTrue);
        expect(ownPostAppearsInTimeline(type, post(PostScope.unlisted)), isTrue);
        expect(
          ownPostAppearsInTimeline(type, post(PostScope.followersOnly)),
          isTrue,
        );
      });

      test('$type: direct は載らない', () {
        expect(ownPostAppearsInTimeline(type, post(PostScope.direct)), isFalse);
      });

      test('$type: localOnly でも公開範囲が通れば載る', () {
        expect(
          ownPostAppearsInTimeline(type, post(PostScope.public, localOnly: true)),
          isTrue,
        );
      });
    }
  });

  group('ownPostAppearsInTimeline — local は public のみ', () {
    test('public は載る', () {
      expect(
        ownPostAppearsInTimeline(TimelineType.local, post(PostScope.public)),
        isTrue,
      );
    });

    test('unlisted / followersOnly / direct は載らない', () {
      expect(
        ownPostAppearsInTimeline(TimelineType.local, post(PostScope.unlisted)),
        isFalse,
      );
      expect(
        ownPostAppearsInTimeline(
          TimelineType.local,
          post(PostScope.followersOnly),
        ),
        isFalse,
      );
      expect(
        ownPostAppearsInTimeline(TimelineType.local, post(PostScope.direct)),
        isFalse,
      );
    });

    test('localOnly な public はローカルには載る', () {
      expect(
        ownPostAppearsInTimeline(
          TimelineType.local,
          post(PostScope.public, localOnly: true),
        ),
        isTrue,
      );
    });
  });

  group('ownPostAppearsInTimeline — federated は public かつ非 localOnly のみ', () {
    test('public は載る', () {
      expect(
        ownPostAppearsInTimeline(TimelineType.federated, post(PostScope.public)),
        isTrue,
      );
    });

    test('localOnly な public は連合には載らない', () {
      expect(
        ownPostAppearsInTimeline(
          TimelineType.federated,
          post(PostScope.public, localOnly: true),
        ),
        isFalse,
      );
    });

    test('unlisted / followersOnly / direct は載らない', () {
      expect(
        ownPostAppearsInTimeline(
          TimelineType.federated,
          post(PostScope.unlisted),
        ),
        isFalse,
      );
      expect(
        ownPostAppearsInTimeline(
          TimelineType.federated,
          post(PostScope.followersOnly),
        ),
        isFalse,
      );
      expect(
        ownPostAppearsInTimeline(TimelineType.federated, post(PostScope.direct)),
        isFalse,
      );
    });
  });

  group('ownPostAppearsInTimeline — directMessages は楽観挿入の対象外', () {
    test('どの公開範囲でも載らない', () {
      for (final scope in PostScope.values) {
        expect(
          ownPostAppearsInTimeline(TimelineType.directMessages, post(scope)),
          isFalse,
          reason: '$scope should not be optimistically inserted into DM list',
        );
      }
    });
  });
}

import 'package:capsicum_backends/src/misskey/extensions.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// #1187: 通知の種別固有フィールドを読む。
///
/// ⚠⚠ **#1177 は種別名を出すところまでだった。**その種別の中身（どのロール /
/// どの予約投稿 / 何を書き出したか）は捨てていたので、**読めても行動できない**
/// 通知になっていた。
///
/// ⚠ **ここは「読んでいること」を固定する。**画面に出る文言は
/// `notification_detail_text_test.dart`（capsicum 側）が持つ。
void main() {
  const host = 'misskey.example';

  MisskeyNotification notification(Map<String, dynamic> overrides) =>
      MisskeyNotification.fromJson({
        'id': 'n1',
        'createdAt': '2026-10-01T00:00:00.000Z',
        ...overrides,
      });

  group('種別固有の荷物を読む (#1187)', () {
    test('roleAssigned: ロールを読む', () {
      final mapped = notification({
        'type': 'roleAssigned',
        'role': {
          'id': 'r1',
          'name': 'モデレーター',
          'color': '#ff0000',
          'iconUrl': 'https://example/icon.png',
        },
      }).toCapsicum(host);

      expect(mapped.type, NotificationType.roleAssigned);
      expect(mapped.assignedRole?.name, 'モデレーター');
      expect(mapped.assignedRole?.color, '#ff0000');
      expect(mapped.assignedRole?.iconUrl, 'https://example/icon.png');
    });

    test('exportCompleted: 対象とファイル ID を読む', () {
      final mapped = notification({
        'type': 'exportCompleted',
        'exportedEntity': 'following',
        'fileId': 'f1',
      }).toCapsicum(host);

      expect(mapped.type, NotificationType.exportCompleted);
      expect(mapped.export?.entity, 'following');
      expect(mapped.export?.fileId, 'f1');
    });

    // ⚠ 片方しか来ない形は作らない（スキーマ上どちらも non-null）が、欠けたら
    // 握り潰すのではなく丸ごと null にする。中途半端な導線を出さないため。
    test('⚠ exportCompleted: fileId が欠けたら export ごと null', () {
      final mapped = notification({
        'type': 'exportCompleted',
        'exportedEntity': 'following',
      }).toCapsicum(host);

      expect(mapped.export, isNull);
    });

    test('⚠⚠ scheduledNotePostFailed: どの予約投稿かを読む', () {
      final mapped = notification({
        'type': 'scheduledNotePostFailed',
        'noteDraft': {
          'id': 'd1',
          // ⚠ epoch ミリ秒の int（ISO 文字列ではない）
          'scheduledAt': 1790000000000,
          'text': '出そびれた投稿',
          'cw': '注意',
          'visibility': 'home',
          'fileIds': ['m1', 'm2'],
        },
      }).toCapsicum(host);

      expect(mapped.type, NotificationType.scheduledPostFailed);
      expect(mapped.failedScheduledPost?.id, 'd1');
      expect(mapped.failedScheduledPost?.content, '出そびれた投稿');
      expect(mapped.failedScheduledPost?.spoilerText, '注意');
      expect(mapped.failedScheduledPost?.visibility, 'home');
      expect(mapped.failedScheduledPost?.mediaIds, ['m1', 'm2']);
      expect(
        mapped.failedScheduledPost?.scheduledAt,
        DateTime.fromMillisecondsSinceEpoch(1790000000000, isUtc: true),
      );
    });

    test('chatRoomInvitationReceived: 招待を読む', () {
      final mapped = notification({
        'type': 'chatRoomInvitationReceived',
        'invitation': {
          'id': 'i1',
          'createdAt': '2026-10-01T00:00:00.000Z',
          'roomId': 'room1',
          'userId': 'u1',
          'room': {
            'id': 'room1',
            'createdAt': '2026-10-01T00:00:00.000Z',
            'name': '実況部屋',
            'ownerId': 'u1',
          },
        },
      }).toCapsicum(host);

      expect(mapped.type, NotificationType.chatInvitation);
      expect(mapped.chatInvitation?.roomId, 'room1');
      expect(mapped.chatInvitation?.room?.name, '実況部屋');
    });

    test('followRequestAccepted: 添えられた一言を読む', () {
      final mapped = notification({
        'type': 'followRequestAccepted',
        'user': {'id': 'u1', 'username': 'alice'},
        'message': 'よろしく',
      }).toCapsicum(host);

      expect(mapped.type, NotificationType.followRequestAccepted);
      expect(mapped.followRequestMessage, 'よろしく');
    });

    // ⚠⚠ **`app` は種別の表に足さない (#1177 の判断)。**あの表は絞り込みの候補の
    // 正本でもあり、使う機会のほぼ無い種別で選択肢だけが増えるため。そのぶん
    // 本文が丸ごと出ないままだったので、未知種別の受け皿（fallback・#1042）に
    // 載せて解消する。
    test('⚠⚠ app: 種別を増やさず fallback に本文を載せる', () {
      final mapped = notification({
        'type': 'app',
        'header': 'みすてむず',
        'body': 'ビルドが完了しました',
        'icon': 'https://example/app.png',
      }).toCapsicum(host);

      expect(
        mapped.type,
        NotificationType.other,
        reason: '表に足すと絞り込みの選択肢が増える（#1177 の判断を崩さない）',
      );
      expect(mapped.fallbackTitle, 'みすてむず');
      expect(mapped.fallbackBody, 'ビルドが完了しました');
    });

    // 対照群。荷物を持たない種別で勝手に埋まらないこと（`type` で分岐せず
    // 「来ていたら読む」形にしているので、ここが崩れると全種別に影響する）。
    test('荷物を持たない種別では何も埋まらない（対照群）', () {
      final mapped = notification({
        'type': 'follow',
        'user': {'id': 'u1', 'username': 'alice'},
      }).toCapsicum(host);

      expect(mapped.assignedRole, isNull);
      expect(mapped.export, isNull);
      expect(mapped.failedScheduledPost, isNull);
      expect(mapped.chatInvitation, isNull);
      expect(mapped.followRequestMessage, isNull);
      expect(mapped.fallbackTitle, isNull);
      expect(mapped.fallbackBody, isNull);
    });
  });

  /// ⚠⚠ **`getScheduledNotes` のパースをここへ寄せた (#1187)。**同じ `NoteDraft`
  /// が通知の `noteDraft` でも来るため。⚠ **寄せる前はテストが 1 本も無かった**
  /// ので、既存の振る舞い（epoch ミリ秒・`scheduledAt` を持たない行を落とす）を
  /// ここで固定する。
  group('misskeyScheduledPostFromMap (#1187 で集約)', () {
    test('epoch ミリ秒を UTC の DateTime にする', () {
      final post = misskeyScheduledPostFromMap({
        'id': 'd1',
        'scheduledAt': 1790000000000,
        'text': 'やあ',
      });

      expect(
        post?.scheduledAt,
        DateTime.fromMillisecondsSinceEpoch(1790000000000, isUtc: true),
      );
      expect(post?.scheduledAt.isUtc, isTrue);
      expect(post?.content, 'やあ');
    });

    // ⚠ `notes/drafts/list` は `scheduled: true` でも素の下書きが混じりうる。
    // 寄せる前の `.where((e) => e['scheduledAt'] != null)` と同じ結末にする。
    test('⚠ scheduledAt が無い行は null（素の下書きを落とす）', () {
      expect(
        misskeyScheduledPostFromMap({'id': 'd1', 'text': 'ただの下書き'}),
        isNull,
      );
    });

    test('⚠ id が無い行も null', () {
      expect(
        misskeyScheduledPostFromMap({'scheduledAt': 1790000000000}),
        isNull,
      );
    });

    // ⚠⚠ ISO 文字列は受けない。`createdAt` と形が違うので、取り違えると
    // 「全部落ちる」か「例外」になる。int 以外は落とす側に倒す。
    test('⚠⚠ scheduledAt が ISO 文字列なら null（int しか受けない）', () {
      expect(
        misskeyScheduledPostFromMap({
          'id': 'd1',
          'scheduledAt': '2026-10-01T00:00:00.000Z',
        }),
        isNull,
      );
    });

    test('fileIds が無ければ空（null にしない）', () {
      final post = misskeyScheduledPostFromMap({
        'id': 'd1',
        'scheduledAt': 1790000000000,
      });

      expect(post?.mediaIds, isEmpty);
    });
  });
}

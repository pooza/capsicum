import 'package:capsicum/src/ui/util/notification_detail_text.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1187: 種別固有の荷物を 1 行の説明に落とす。
///
/// ⚠⚠ **読み込みは `misskey_notification_payload_test.dart`（backends）が持つ。**
/// ここは「読んだものが画面の文言になるか」だけを見る。
void main() {
  Notification notification({
    NotificationType type = NotificationType.other,
    UserRole? assignedRole,
    ExportCompletion? export,
    ScheduledPost? failedScheduledPost,
    ChatRoomInvitation? chatInvitation,
    String? followRequestMessage,
  }) => Notification(
    id: 'n1',
    type: type,
    createdAt: DateTime.utc(2026, 10, 1),
    assignedRole: assignedRole,
    export: export,
    failedScheduledPost: failedScheduledPost,
    chatInvitation: chatInvitation,
    followRequestMessage: followRequestMessage,
  );

  test('ロール名を出す', () {
    expect(
      notificationDetailText(
        notification(
          type: NotificationType.roleAssigned,
          assignedRole: const UserRole(id: 'r1', name: 'モデレーター'),
        ),
      ),
      'モデレーター',
    );
  });

  test('書き出した対象を日本語で出す', () {
    expect(
      notificationDetailText(
        notification(
          type: NotificationType.exportCompleted,
          export: const ExportCompletion(entity: 'following', fileId: 'f1'),
        ),
      ),
      'フォローを書き出しました',
    );
  });

  // ⚠⚠ **上流が種類を増やしたときに「何を書き出したか分からない」へ戻さない。**
  // 英語のままでも出ているほうがまし。
  test('⚠⚠ 知らない対象はそのまま出す（握り潰さない）', () {
    expect(
      notificationDetailText(
        notification(
          type: NotificationType.exportCompleted,
          export: const ExportCompletion(entity: 'newThing', fileId: 'f1'),
        ),
      ),
      'newThingを書き出しました',
    );
    expect(exportedEntityLabel('customEmoji'), 'カスタム絵文字');
  });

  test('⚠⚠ 失敗した予約投稿は本文を出す（どれが失敗したか）', () {
    expect(
      notificationDetailText(
        notification(
          type: NotificationType.scheduledPostFailed,
          failedScheduledPost: ScheduledPost(
            id: 'd1',
            scheduledAt: DateTime.utc(2026, 10, 1, 12, 34),
            content: '出そびれた投稿',
          ),
        ),
      ),
      '出そびれた投稿',
    );
  });

  // ⚠ 添付だけの予約投稿は本文が空。それでも「どれか」を示す必要がある。
  test('⚠ 本文が空の予約投稿は予約時刻で示す', () {
    final detail = notificationDetailText(
      notification(
        type: NotificationType.scheduledPostFailed,
        failedScheduledPost: ScheduledPost(
          id: 'd1',
          scheduledAt: DateTime.utc(2026, 10, 1, 12, 34),
          content: '   ',
        ),
      ),
    );

    // ⚠ 端末のローカル時刻へ寄せるので、時刻そのものは固定しない。形だけ見る。
    expect(detail, matches(RegExp(r'^\d{2}/\d{2} \d{2}:\d{2} に予約していた投稿$')));
  });

  test('招待はルーム名を出す', () {
    expect(
      notificationDetailText(
        notification(
          type: NotificationType.chatInvitation,
          chatInvitation: ChatRoomInvitation(
            id: 'i1',
            createdAt: DateTime.utc(2026, 10, 1),
            roomId: 'room1',
            userId: 'u1',
            room: ChatRoom(
              id: 'room1',
              name: '実況部屋',
              description: '',
              ownerId: 'u1',
              owner: const User(id: 'u1', username: 'alice'),
              createdAt: DateTime.utc(2026, 10, 1),
            ),
          ),
        ),
      ),
      '実況部屋',
    );
  });

  test('フォロー承認の一言を出す', () {
    expect(
      notificationDetailText(
        notification(
          type: NotificationType.followRequestAccepted,
          followRequestMessage: 'よろしく',
        ),
      ),
      'よろしく',
    );
  });

  // ⚠ 空文字で 1 行ぶんの余白だけが増える形にしない。
  test('⚠ 空の値は行を作らない', () {
    expect(
      notificationDetailText(
        notification(
          type: NotificationType.followRequestAccepted,
          followRequestMessage: '   ',
        ),
      ),
      isNull,
    );
    expect(
      notificationDetailText(
        notification(
          type: NotificationType.roleAssigned,
          assignedRole: const UserRole(id: 'r1', name: ''),
        ),
      ),
      isNull,
    );
  });

  // 対照群。荷物が無ければ何も出さない（説明行が常に出ると全通知が 1 行太る）。
  test('荷物が無ければ null（対照群）', () {
    expect(
      notificationDetailText(notification(type: NotificationType.follow)),
      isNull,
    );
  });
}

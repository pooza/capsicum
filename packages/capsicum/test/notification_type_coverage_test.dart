import 'dart:io';

import 'package:capsicum/src/ui/util/notification_type_display.dart';
import 'package:capsicum_backends/src/mastodon/extensions.dart';
import 'package:capsicum_backends/src/misskey/extensions.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 通知種別のマッピングの取りこぼしを機械で見る (#1177)。
///
/// ⚠⚠ **同じ対応表が 4 か所にある。**片方だけ足すと、
/// **「アプリ内では読めるが、プッシュだけ『通知』のまま」**という割れ方をする
/// （実際に `quote` がその状態で出荷されていた）。
///
/// | | 役割 |
/// | --- | --- |
/// | `mastodonNotificationTypeMap` / `misskeyNotificationTypeMap` | REST（アプリ内） |
/// | `notificationTypeFromString` | push payload（Dart 側） |
/// | ⚠ `ios/` と `macos/` の `NotificationTypeLabel.swift` | **プッシュの見出し** |
void main() {
  /// ⚠ **ここが空振りしないことを先に確かめる。**ファイルが読めなければ検査に
  /// ならないので、`sourceOf` は**中身が空でないこと**を assert する。
  String sourceOf(String path) {
    final file = File(path);
    final source = file.existsSync() ? file.readAsStringSync() : '';

    expect(source, isNotEmpty, reason: '検査対象を読めていない: $path');
    return source;
  }

  const iosLabel =
      'ios/CapsicumNotificationService/NotificationTypeLabel.swift';
  const macosLabel =
      'macos/CapsicumNotificationService/NotificationTypeLabel.swift';

  group('#1177 種別マッピングの網羅', () {
    // ⚠⚠ **この Issue でいちばん実害がある種別。**capsicum 自身が予約投稿を
    // 作れるのに、失敗が「通知」としか出ないと「投稿したつもりが出ていない」に
    // 気づけない。
    test('予約投稿の失敗が読める（REST / push / ネイティブの 3 経路とも）', () {
      expect(
        misskeyNotificationTypeMap['scheduledNotePostFailed'],
        NotificationType.scheduledPostFailed,
      );
      expect(
        notificationTypeFromString('scheduledNotePostFailed'),
        NotificationType.scheduledPostFailed,
      );
      expect(sourceOf(iosLabel), contains('"scheduledNotePostFailed"'));
      expect(
        notificationTypeDisplay(NotificationType.scheduledPostFailed).label,
        isNot('通知'),
      );
    });

    // ⚠⚠ **2 ファイルは完全に同一に保つ。**片方だけ直すと iOS と macOS で
    // プッシュの見出しが割れる。
    test('ネイティブの写し 2 ファイルが同一', () {
      expect(sourceOf(macosLabel), sourceOf(iosLabel));
    });

    // ⚠ REST の表に在る種別は、push 側にも綴りが在ること。
    test('REST で知っている種別は push payload からも読める', () {
      for (final wire in [
        ...mastodonNotificationTypeMap.keys,
        ...misskeyNotificationTypeMap.keys,
      ]) {
        expect(
          notificationTypeFromString(wire),
          isNot(NotificationType.other),
          reason: 'push payload から読めない: $wire',
        );
      }
    });

    // ⚠ 未知の種別の受け皿は残す（上流はこれからも増える）。
    test('知らない種別は other に落ちる', () {
      expect(
        notificationTypeFromString('brand_new_type'),
        NotificationType.other,
      );
      expect(notificationTypeDisplay(NotificationType.other).label, '通知');
    });

    // ⚠⚠ **`app` / `test` は入れない。**表は絞り込みの候補の正本でもあるので、
    // 使う機会のほぼ無い種別で選択肢だけが増える。
    test('app / test は絞り込みの候補に出さない', () {
      expect(misskeyNotificationTypeMap.containsKey('app'), isFalse);
      expect(misskeyNotificationTypeMap.containsKey('test'), isFalse);
    });
  });

  group('#1177 quote を mention から外した', () {
    // ⚠⚠ **寄せると種別フィルタで切り分けられない**（表が送信名の正本・#1042）。
    test('quote は独立した種別', () {
      expect(notificationTypeFromString('quote'), NotificationType.quote);
      expect(mastodonNotificationTypeMap['quote'], NotificationType.quote);
      expect(misskeyNotificationTypeMap['quote'], NotificationType.quote);
      expect(notificationTypeDisplay(NotificationType.quote).label, '引用');
    });

    // ⚠ reply は従来どおり mention のまま（寄せる前例がある）。
    test('reply は mention のまま', () {
      expect(notificationTypeFromString('reply'), NotificationType.mention);
    });

    // ⚠ ネイティブ側も外す。片方だけだとプッシュの見出しが割れる。
    test('ネイティブも quote を「メンション」に含めない', () {
      expect(
        sourceOf(iosLabel),
        isNot(contains('"mention", "reply", "quote"')),
      );
      expect(sourceOf(iosLabel), contains('return "引用"'));
    });
  });

  group('#1177 寄せてはいけない種別', () {
    // ⚠⚠ `newChatMessage`（メッセージが来た）と招待は別物。寄せると見出しが嘘になる。
    test('チャットの招待はメッセージに寄せない', () {
      expect(
        misskeyNotificationTypeMap['chatRoomInvitationReceived'],
        NotificationType.chatInvitation,
      );
      expect(
        notificationTypeFromString('newChatMessage'),
        NotificationType.chat,
      );
      expect(
        notificationTypeDisplay(NotificationType.chatInvitation).label,
        isNot(notificationTypeDisplay(NotificationType.chat).label),
      );
    });

    // ⚠ Mastodon の `status` と Misskey の `note` は同じ概念なので 1 つに寄せる。
    test('status と note は同じ種別へ寄せる', () {
      expect(mastodonNotificationTypeMap['status'], NotificationType.newPost);
      expect(misskeyNotificationTypeMap['note'], NotificationType.newPost);
    });
  });
}

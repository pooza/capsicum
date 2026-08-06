import 'package:capsicum/src/service/notification_tag.dart';
import 'package:flutter_test/flutter_test.dart';

/// WebSocket 経路と WNS 経路のトースト Tag を揃えるためのハッシュ (#933)。
///
/// **ここのベクタは `windows/runner/notification_tag_test.cpp` と同一の値を
/// 使っている。**片方だけ変えると Tag が食い違い、Windows で二重通知が復活
/// する。値を変えるときは必ず両方を更新すること。
void main() {
  group('stableNotificationTag', () {
    // native 側と共有するテストベクタ。
    const vectors = <String, int>{
      '': 18652613,
      'a': 1678518572,
      'pooza@mstdn.b-shock.org|123456': 70693920,
      // マルチバイト。UTF-8 バイト列に対して計算していることの確認
      // （native の std::string と同じ結果になる保証）。
      'ぷーざ@misskey.delmulin.com|9abc': 1901567813,
    };

    for (final entry in vectors.entries) {
      test('"${entry.key}" → ${entry.value}', () {
        expect(stableNotificationTag(entry.key), entry.value);
      });
    }

    test('常に 31bit の非負整数になる', () {
      for (final key in vectors.keys) {
        final tag = stableNotificationTag(key);
        expect(tag, greaterThanOrEqualTo(0));
        expect(tag, lessThanOrEqualTo(0x7fffffff));
      }
    });

    test('通知 ID が 1 違えば別の値になる', () {
      expect(
        stableNotificationTag('pooza@mstdn.b-shock.org|123456'),
        isNot(stableNotificationTag('pooza@mstdn.b-shock.org|123457')),
      );
    });

    test('アカウントが違えば別の値になる（横断 dedup の衝突回避）', () {
      expect(
        stableNotificationTag('pooza@mstdn.b-shock.org|123456'),
        isNot(stableNotificationTag('pooza@mstdn.delmulin.com|123456')),
      );
    });
  });

  group('notificationTagKey', () {
    test('relay / NSE と同じ ID 空間のキーを組む', () {
      expect(
        notificationTagKey(
          account: 'pooza@mstdn.b-shock.org',
          notificationId: '123456',
        ),
        'pooza@mstdn.b-shock.org|123456',
      );
    });
  });
}

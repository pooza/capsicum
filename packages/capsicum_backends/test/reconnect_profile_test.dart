import 'package:capsicum_backends/src/mastodon/notification_streaming.dart';
import 'package:capsicum_backends/src/mastodon/streaming.dart';
import 'package:capsicum_backends/src/misskey/chat_room_streaming.dart';
import 'package:capsicum_backends/src/misskey/chat_streaming.dart';
import 'package:capsicum_backends/src/misskey/notification_streaming.dart';
import 'package:capsicum_backends/src/misskey/streaming.dart';
import 'package:capsicum_backends/src/reconnecting_socket.dart';
import 'package:test/test.dart';

/// 再接続の値は 2 種類のまま寄せた (#1340・2026-10-27 pooza 判断)。
///
/// ⚠ 寄せる前は 4 本がそれぞれ定数を持っていた。値と「どれがどちらか」を
/// ここで固定し、寄せたことで値が揃ってしまう / 入れ替わることを落とす。
void main() {
  group('値の組', () {
    test('即時（タイムライン）は 1 秒・上限 60 秒・ping 30 秒', () {
      expect(ReconnectProfile.live.baseDelay, const Duration(seconds: 1));
      expect(ReconnectProfile.live.maxDelay, const Duration(seconds: 60));
      expect(ReconnectProfile.live.pingInterval, const Duration(seconds: 30));
    });

    test('常駐（通知・チャット）は 5 秒・上限 60 秒・ping 60 秒', () {
      expect(ReconnectProfile.resident.baseDelay, const Duration(seconds: 5));
      expect(ReconnectProfile.resident.maxDelay, const Duration(seconds: 60));
      expect(
        ReconnectProfile.resident.pingInterval,
        const Duration(seconds: 60),
      );
    });
  });

  group('どの接続がどちらの組か', () {
    const host = 'example.com';
    const token = 'token';

    final live = <String, ReconnectTuning>{
      'Mastodon のタイムライン': MastodonStreaming(host: host, accessToken: token),
      'Misskey のタイムライン': MisskeyStreaming(host: host, accessToken: token),
    };
    final resident = <String, ReconnectTuning>{
      'Mastodon の通知': MastodonNotificationStreaming(
        host: host,
        accessToken: token,
      ),
      'Misskey の通知': MisskeyNotificationStreaming(
        host: host,
        accessToken: token,
      ),
      'Misskey のチャット': MisskeyChatStreaming(host: host, accessToken: token),
      'Misskey のチャットルーム': MisskeyChatRoomStreaming(
        host: host,
        accessToken: token,
        roomId: 'room',
      ),
    };

    for (final MapEntry(key: name, value: tuning) in live.entries) {
      test('$name は即時', () {
        expect(tuning.reconnectProfile, same(ReconnectProfile.live));
        // jitter で半分〜初動の値に収まる（初動 1 秒）。
        expect(
          tuning.reconnectDelayFor(0).inMilliseconds,
          inInclusiveRange(500, 1000),
        );
      });
    }

    for (final MapEntry(key: name, value: tuning) in resident.entries) {
      test('$name は常駐', () {
        expect(tuning.reconnectProfile, same(ReconnectProfile.resident));
        // 初動 5 秒（jitter で 2.5〜5 秒）。
        expect(
          tuning.reconnectDelayFor(0).inMilliseconds,
          inInclusiveRange(2500, 5000),
        );
      });
    }

    test('どちらも 60 秒で頭打ち', () {
      for (final MapEntry(key: name, value: tuning) in {
        ...live,
        ...resident,
      }.entries) {
        for (final attempt in [3, 10, 100]) {
          expect(
            tuning.reconnectDelayFor(attempt),
            lessThanOrEqualTo(const Duration(seconds: 60)),
            reason: '$name attempt=$attempt',
          );
        }
      }
    });
  });
}

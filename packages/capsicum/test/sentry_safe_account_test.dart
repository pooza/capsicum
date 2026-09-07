import 'package:capsicum/src/model/account_key.dart';
import 'package:capsicum/src/util/sentry_tag_hash.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1035-B1: breadcrumb に載せるアカウント識別子。
///
/// 潰すのは username だけで、**host はそのまま出す**（プリセットサーバーかどうか
/// でトリアージの優先度を切る運用があり、素性が分からないと切れない）。
/// [sentrySafeAccountKey] はその入口を 1 本にするための関数で、storage key
/// (`mastodon://user@host`) と relay payload の `user@host` の**どちらで渡しても
/// 同じ結果**になる必要がある。
void main() {
  const username = 'alice';
  const host = 'mstdn.b-shock.org';

  group('sentrySafeAccountKey', () {
    test('storage key と payload の user@host で同じ結果になる (#1035-B1)', () {
      const storageKey = 'mastodon://$username@$host';
      const payloadAccount = '$username@$host';

      expect(
        sentrySafeAccountKey(payloadAccount),
        sentrySafeAccountKey(storageKey),
        reason:
            'push_message_dispatcher は payload 側の形で渡す。呼び分けを規約で守ると '
            '次に同じ穴を踏むので、関数がどちらも受ける',
      );
    });

    test('username は潰し、host はそのまま残す', () {
      final safe = sentrySafeAccountKey('$username@$host');

      expect(safe, '${hashForSentryTag(username)}@$host');
      expect(
        safe.contains(username),
        isFalse,
        reason: 'release では debugPrint が丸ごと breadcrumb 化される',
      );
      expect(safe.endsWith('@$host'), isTrue, reason: 'host で優先度を切るので、ここは残す');
    });

    test('AccountKey 経路と同じ値になる', () {
      final key = AccountKey(
        type: BackendType.mastodon,
        host: host,
        username: username,
      );
      expect(sentrySafeAccountKey(key.toStorageKey()), sentrySafeAccount(key));
    });

    test('本当に読めない形は「読めなかった」と分かる形にする', () {
      // 元の文字列を出さない。壊れているときだけ素通しでは意味が無い。
      for (final broken in const [
        '',
        'alice',
        '@$host',
        '$username@',
        'pleroma://$username@$host', // scheme はあるが未知の backend
      ]) {
        expect(
          sentrySafeAccountKey(broken),
          '(unparsable-account-key)',
          reason: broken,
        );
      }
    });
  });
}

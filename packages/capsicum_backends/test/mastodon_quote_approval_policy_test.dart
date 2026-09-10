import 'package:capsicum_backends/src/mastodon/extensions.dart';
import 'package:fediverse_objects/fediverse_objects.dart';
import 'package:test/test.dart';

/// #1113: 投稿者が設定した引用許可を `quote_approval.automatic` から戻す。
///
/// 削除して再編集で元の設定を引き継ぐのに使う。引き継がないと未選択のまま
/// 送られ、サーバーはアカウント既定を使う（「許可しない」が「誰でも」へ広がる）。
void main() {
  MastodonStatus status(Map<String, dynamic> overrides) =>
      MastodonStatus.fromJson({
        'id': '1',
        'created_at': '2026-09-11T00:00:00Z',
        'account': {
          'id': '1',
          'username': 'pooza',
          'acct': 'pooza',
          'display_name': 'pooza',
          'note': '',
          'avatar': '',
          'header': '',
          'followers_count': 0,
          'following_count': 0,
          'statuses_count': 0,
          'fields': <Map<String, dynamic>>[],
        },
        'content': '<p>ほげ</p>',
        'visibility': 'public',
        'favourites_count': 0,
        'reblogs_count': 0,
        'replies_count': 0,
        'media_attachments': <Map<String, dynamic>>[],
        ...overrides,
      });

  Map<String, dynamic> approval(List<String> automatic) => {
    'automatic': automatic,
    'manual': <String>[],
    'current_user': 'automatic',
  };

  group('parseMastodonQuoteApprovalPolicy', () {
    test('public → public', () {
      expect(parseMastodonQuoteApprovalPolicy(approval(['public'])), 'public');
    });

    test('followers → followers', () {
      expect(
        parseMastodonQuoteApprovalPolicy(approval(['followers'])),
        'followers',
      );
    });

    test('⚠ 空は nobody（Mastodon WebUI の `|| \'nobody\'` と同じ）', () {
      expect(parseMastodonQuoteApprovalPolicy(approval([])), 'nobody');
    });

    test('⚠⚠ 知らないフラグだけなら nobody へ倒す（再編集で許可を広げない）', () {
      expect(
        parseMastodonQuoteApprovalPolicy(approval(['following'])),
        'nobody',
      );
      expect(
        parseMastodonQuoteApprovalPolicy(approval(['disabled'])),
        'nobody',
      );
    });

    test('⚠ 先頭が unsupported_policy でも、後ろの既知の値を拾う', () {
      // WebUI の `automatic[0]` はここで `unsupported_policy` を返してしまう。
      expect(
        parseMastodonQuoteApprovalPolicy(
          approval(['unsupported_policy', 'public']),
        ),
        'public',
      );
    });

    test('automatic が配列でなければ nobody', () {
      expect(
        parseMastodonQuoteApprovalPolicy({'automatic': 'public'}),
        'nobody',
      );
    });

    test('quote_approval が無い（4.5 未満）なら null ＝何も送らない', () {
      expect(parseMastodonQuoteApprovalPolicy(null), isNull);
    });
  });

  group('MastodonStatus.toCapsicum', () {
    test('quote_approval から quoteApprovalPolicy が入る', () {
      final post = status({
        'quote_approval': approval(['followers']),
      }).toCapsicum('example.com');
      expect(post.quoteApprovalPolicy, 'followers');
    });

    test('⚠ quotable（読む側）とは独立している', () {
      // 自分の投稿は current_user が automatic（自分は常に引用できる）でも、
      // 他人に許した範囲は nobody でありうる。
      final post = status({
        'quote_approval': approval([]),
      }).toCapsicum('example.com');
      expect(post.quotable, isTrue);
      expect(post.quoteApprovalPolicy, 'nobody');
    });

    test('quote_approval が無ければ null', () {
      expect(status({}).toCapsicum('example.com').quoteApprovalPolicy, isNull);
    });
  });
}

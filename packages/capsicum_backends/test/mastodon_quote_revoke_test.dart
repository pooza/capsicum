import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1213: 引用された側・引用を許す側の道具（Mastodon 4.5 以降）。
///
/// - 自分の投稿への引用を撤回する
/// - 投稿したあとに引用の許可を変える
class _Recorder implements HttpClientAdapter {
  _Recorder(this.body);

  final Map<String, dynamic> body;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _status({
  required String id,
  Map<String, dynamic>? quote,
  Map<String, dynamic>? quoteApproval,
}) => {
  'id': id,
  'created_at': '2026-10-14T00:00:00.000Z',
  'content': '<p>body</p>',
  'visibility': 'public',
  'account': {
    'id': 'a1',
    'username': 'someone',
    'acct': 'someone',
    'display_name': 'someone',
    'note': '',
    'avatar': '',
    'header': '',
    'followers_count': 0,
    'following_count': 0,
    'statuses_count': 0,
    'fields': <Map<String, dynamic>>[],
  },
  'favourites_count': 0,
  'reblogs_count': 0,
  'replies_count': 0,
  'media_attachments': <Map<String, dynamic>>[],
  'quote': ?quote,
  'quote_approval': ?quoteApproval,
};

void main() {
  test('引用の撤回: 引用された側の id と、引用した側の id を経路に載せる', () async {
    final adapter = await MastodonAdapter.create('example.com');
    final http = _Recorder(
      _status(
        id: 'quoting',
        quote: {'state': 'revoked', 'quoted_status': null},
      ),
    );
    adapter.client.dio.httpClientAdapter = http;

    final updated = await (adapter as QuoteSupport).revokeQuote(
      quotedPostId: 'mine',
      quotingPostId: 'quoting',
    );

    final request = http.requests.single;
    expect(request.method, 'POST');
    expect(
      request.path,
      '/api/v1/statuses/mine/quotes/quoting/revoke',
      reason: '⚠ 順番を逆にすると、他人の投稿への引用を撤回しに行く',
    );
    // 戻り値は引用した側の投稿で、引用は外れている。
    expect(updated.id, 'quoting');
    expect(updated.quote, isNull);
    expect(updated.quoteState, QuoteState.revoked);
  });

  test('引用の許可の変更: quote_approval_policy だけを送る', () async {
    final adapter = await MastodonAdapter.create('example.com');
    final http = _Recorder(
      _status(
        id: 'mine',
        quoteApproval: {
          'automatic': <String>[],
          'manual': <String>[],
          'current_user': 'automatic',
        },
      ),
    );
    adapter.client.dio.httpClientAdapter = http;

    final updated = await (adapter as QuoteSupport).setQuoteApprovalPolicy(
      'mine',
      'nobody',
    );

    final request = http.requests.single;
    expect(request.method, 'PUT');
    expect(request.path, '/api/v1/statuses/mine/interaction_policy');
    expect(request.data, {'quote_approval_policy': 'nobody'});
    expect(updated.quoteApprovalPolicy, 'nobody');
  });
}

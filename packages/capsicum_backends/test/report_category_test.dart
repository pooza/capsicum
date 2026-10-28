import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1257: 通報に分類（`category`）と違反したルール（`rule_ids`）を添える。
///
/// ⚠ サーバー側の決まり（Mastodon の `Report` / `ReportService`）:
/// - `category` を送らなければ `other` として受ける
/// - `rule_ids` を送ると、分類は `violation` に書き換えられる
/// - `violation` なのに `rule_ids` が空だと断る
class _Recorder implements HttpClientAdapter {
  _Recorder({this.rules, this.rulesStatus = 200});

  final List<Map<String, dynamic>>? rules;
  final int rulesStatus;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final isRules = options.path == '/api/v1/instance/rules';
    return ResponseBody.fromString(
      jsonEncode(isRules ? (rules ?? const []) : <String, dynamic>{}),
      isRules ? rulesStatus : 200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _body(RequestOptions options) =>
    options.data as Map<String, dynamic>;

void main() {
  group('Mastodon', () {
    late MastodonAdapter adapter;
    late _Recorder recorder;

    Future<void> setUpWith(_Recorder r) async {
      adapter = await MastodonAdapter.create('example.com');
      recorder = r;
      adapter.client.dio.httpClientAdapter = recorder;
    }

    setUp(() => setUpWith(_Recorder()));

    test('分類を添えられる', () {
      expect(adapter.supportsReportCategory, isTrue);
    });

    test('⚠ 「その他」は送らない（分類を足す前と同じ本文）', () async {
      await adapter.reportPost('100', '7', category: ReportCategory.other);
      await adapter.reportUser('7');

      expect(_body(recorder.requests[0]), {
        'account_id': '7',
        'status_ids': ['100'],
      });
      expect(_body(recorder.requests[1]), {'account_id': '7'});
    });

    test('「スパム」は category だけを送る', () async {
      await adapter.reportUser('7', category: ReportCategory.spam);

      expect(_body(recorder.requests.single), {
        'account_id': '7',
        'category': 'spam',
      });
    });

    test('「違法な内容」は legal', () async {
      await adapter.reportPost('100', '7', category: ReportCategory.legal);

      expect(_body(recorder.requests.single)['category'], 'legal');
    });

    test('「違反」はルールを添える', () async {
      await adapter.reportPost(
        '100',
        '7',
        category: ReportCategory.violation,
        ruleIds: ['1', '3'],
      );

      expect(_body(recorder.requests.single), {
        'account_id': '7',
        'status_ids': ['100'],
        'category': 'violation',
        'rule_ids': ['1', '3'],
      });
    });

    test('⚠⚠ 「違反」以外ではルールを送らない（送ると分類が「違反」に書き換わる）', () async {
      await adapter.reportUser(
        '7',
        category: ReportCategory.spam,
        ruleIds: ['1'],
      );

      expect(_body(recorder.requests.single).containsKey('rule_ids'), isFalse);
    });

    group('ルールの読み込み', () {
      test('id・本文・補足を読み、日本語の翻訳があればそちらを使う', () async {
        await setUpWith(
          _Recorder(
            rules: [
              {
                'id': '1',
                'text': 'No racism',
                'hint': 'Be nice',
                'translations': {
                  'ja': {'text': '差別をしない', 'hint': '仲良く'},
                },
              },
              {'id': '2', 'text': 'スパムをしない', 'hint': ''},
            ],
          ),
        );

        final rules = await adapter.getReportRules();

        expect(recorder.requests.single.path, '/api/v1/instance/rules');
        expect(rules.map((r) => (r.id, r.text, r.hint)), [
          ('1', '差別をしない', '仲良く'),
          ('2', 'スパムをしない', null),
        ]);
      });

      test('本文の無いルールは落とす', () async {
        await setUpWith(
          _Recorder(
            rules: [
              {'id': '1', 'text': ''},
              {'id': '2', 'text': 'ある'},
            ],
          ),
        );

        final rules = await adapter.getReportRules();

        expect(rules.map((r) => r.id), ['2']);
      });

      test('⚠ 読めなければ空（通報そのものは止めない）', () async {
        await setUpWith(_Recorder(rulesStatus: 404));

        expect(await adapter.getReportRules(), isEmpty);
      });
    });
  });

  group('Misskey', () {
    test('⚠ 分類を添えられない（report-abuse に分類の口が無い）', () async {
      final adapter = await MisskeyAdapter.create('example.com');
      expect(adapter.supportsReportCategory, isFalse);
      expect(await adapter.getReportRules(), isEmpty);
    });
  });
}

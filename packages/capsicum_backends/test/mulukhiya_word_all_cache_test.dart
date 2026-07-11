import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #687 一括取得 + ローカル絞り込みのサービス層。suggestWordsLocal が
/// `/word/all` を一度だけ取得してローカル絞り込みし、TTL 内は再取得せず、
/// 一括取得が使えない/正規化の穴のときだけ `/word/suggest` に fallback する
/// ことを検証する。
class _WordAdapter implements HttpClientAdapter {
  _WordAdapter({this.wordAllStatus = 200, List<Object>? dictionary})
    : dictionary = dictionary ?? _dictionary;

  final int wordAllStatus;
  final List<Object> dictionary;

  int wordAllCount = 0;
  int wordSuggestCount = 0;

  static const _dictionary = [
    {'surface': '閃華裂光拳', 'reading': 'センカレッコウケン', 'category': '技名'},
    {'surface': '戦火', 'reading': 'センカ'},
    {'surface': '挑戦', 'reading': 'チョウセン'},
  ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path.endsWith('/word/all')) {
      wordAllCount++;
      if (wordAllStatus != 200) return _json({'error': 'nope'}, wordAllStatus);
      return _json({
        'words': dictionary,
        'size': dictionary.length,
        'digest': 'deadbeef',
      }, 200);
    }
    if (path.endsWith('/word/suggest')) {
      wordSuggestCount++;
      // fallback で来たと分かるマーカー候補を返す。
      return _json({
        'candidates': [
          {'surface': 'サーバー由来', 'reading': 'サーバーユライ'},
        ],
      }, 200);
    }
    // /about（detect 用・word_suggest 有効）。
    return _json({
      'package': {'version': '5.27.0'},
      'config': {
        'controller': 'mastodon',
        'features': {'word_suggest': true},
      },
    }, 200);
  }

  ResponseBody _json(Object body, int status) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );

  @override
  void close({bool force = false}) {}
}

Future<({MulukhiyaService service, _WordAdapter adapter})> _build({
  int wordAllStatus = 200,
  List<Object>? dictionary,
}) async {
  final adapter = _WordAdapter(
    wordAllStatus: wordAllStatus,
    dictionary: dictionary,
  );
  final dio = Dio()..httpClientAdapter = adapter;
  final service = await MulukhiyaService.detect(dio, 'h.example');
  return (service: service!, adapter: adapter);
}

void main() {
  group('MulukhiyaService.suggestWordsLocal (#687)', () {
    test('一括取得してローカル絞り込み・word/suggest は叩かない', () async {
      final b = await _build();
      final r = await b.service.suggestWordsLocal(q: 'せんか');
      expect(r.map((e) => e.surface), ['戦火', '閃華裂光拳']);
      expect(b.adapter.wordAllCount, 1);
      expect(b.adapter.wordSuggestCount, 0);
    });

    test('TTL 内の 2 回目はキャッシュを使い /word/all を再取得しない', () async {
      final b = await _build();
      await b.service.suggestWordsLocal(q: 'せんか');
      await b.service.suggestWordsLocal(q: 'ちょうせん');
      expect(b.adapter.wordAllCount, 1);
      expect(b.adapter.wordSuggestCount, 0);
    });

    test('純粋なかなのローカル 0 件は確定・fallback しない', () async {
      final b = await _build();
      final r = await b.service.suggestWordsLocal(q: 'ぬるぽ');
      expect(r, isEmpty);
      expect(b.adapter.wordSuggestCount, 0);
    });

    test('正規化の穴（半角カナ）でローカル 0 件なら word/suggest に fallback', () async {
      final b = await _build();
      final r = await b.service.suggestWordsLocal(q: 'ｾﾝｶ');
      expect(r.map((e) => e.surface), ['サーバー由来']);
      expect(b.adapter.wordSuggestCount, 1);
    });

    test('/word/all 未対応（404）なら全部 word/suggest に fallback', () async {
      final b = await _build(wordAllStatus: 404);
      final r = await b.service.suggestWordsLocal(q: 'せんか');
      expect(r.map((e) => e.surface), ['サーバー由来']);
      expect(b.adapter.wordSuggestCount, 1);
    });

    test('想定外型の category を含んでも辞書全体が死なない (#821)', () async {
      // category が数値のエントリ。以前は `as String?` の TypeError が
      // `on DioException` catch を抜け、.toList() が辞書全体を巻き添えに飛ばして
      // 都度クエリ fallback に落ちていた。型ガード後は該当エントリだけ category
      // を null に倒して残りごと生かす。
      final b = await _build(
        dictionary: const [
          {'surface': '戦火', 'reading': 'センカ', 'category': 42},
          {'surface': '挑戦', 'reading': 'チョウセン'},
        ],
      );
      final r = await b.service.suggestWordsLocal(q: 'せんか');
      expect(r.map((e) => e.surface), ['戦火']);
      expect(r.single.category, isNull);
      // 辞書が生きているので都度クエリには落ちない。
      expect(b.adapter.wordSuggestCount, 0);
    });

    test('surface/reading が非 String のエントリは除外し、残りは生かす (#821)', () async {
      final b = await _build(
        dictionary: const [
          {'surface': 123, 'reading': 'センカ'},
          {'surface': '挑戦', 'reading': 'チョウセン'},
        ],
      );
      final r = await b.service.suggestWordsLocal(q: 'ちょうせん');
      expect(r.map((e) => e.surface), ['挑戦']);
      expect(b.adapter.wordSuggestCount, 0);
    });

    test('prewarm 後は最初の suggestWordsLocal で /word/all を再取得しない', () async {
      final b = await _build();
      await b.service.prewarmWordDictionary();
      expect(b.adapter.wordAllCount, 1);
      await b.service.suggestWordsLocal(q: 'せんか');
      expect(b.adapter.wordAllCount, 1);
    });
  });
}

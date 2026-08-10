import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #965 / mulukhiya #4540: `GET /mulukhiya/api/program` の**並び順をサーバーに
/// 委ねている**ことを固定する。
///
/// モロヘイヤ 5.32.0 以降、`/program` は放送順 (`next_on` 昇順 → `start_time`
/// 昇順、`next_on` を持たない「毎日」枠は末尾) で返す。エントリのキーは SHA256
/// の先頭 12 桁固定で JS の配列インデックスにならないため JSON を通しても挿入順
/// が保たれ、Dart 側も `jsonDecode` が `LinkedHashMap` を返すのでそのまま使える。
///
/// クライアントは並べ替えを一切持たない。`SplayTreeMap` へ変える・`sort` を
/// 足す・フィルタを別のコレクション経由にする、といった変更で順序は黙って
/// 壊れるため、ここで固定しておく。
///
/// 併せて `start_time` / `next_on` のパースと degrade も検証する。
class _ProgramAdapter implements HttpClientAdapter {
  _ProgramAdapter(this.program);

  final Map<String, dynamic> program;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = options.path.endsWith('/about')
        ? jsonEncode({
            'package': {'version': '5.32.0'},
            'config': {'controller': 'mastodon'},
          })
        : jsonEncode(program);
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<MulukhiyaService> _service(Map<String, dynamic> program) async {
  final dio = Dio()..httpClientAdapter = _ProgramAdapter(program);
  final service = await MulukhiyaService.detect(dio, 'h.example');
  return service!;
}

Map<String, dynamic> _entry({
  required String series,
  String? nextOn,
  String? startTime,
  bool enable = true,
}) => {
  'series': series,
  'enable': enable,
  'next_on': ?nextOn,
  'start_time': ?startTime,
};

void main() {
  group('getProgram はサーバーの並び順を保つ (#965)', () {
    test('放送順のレスポンスがそのままの順で返る', () async {
      // 美食丼の実レスポンスと同じ形（放送順・「毎日」枠が末尾）。
      final service = await _service({
        '34cc5457e423': _entry(
          series: '名探偵プリキュア！',
          nextOn: '2026-08-09',
          startTime: '08:30',
        ),
        '9406f89ea15a': _entry(
          series: 'Yes！プリキュア5 鏡の国のミラクル大冒険',
          nextOn: '2026-08-09',
          startTime: '19:00',
        ),
        'f6fdc831fd4b': _entry(
          series: 'わんだふるぷりきゅあ！',
          nextOn: '2026-08-12',
          startTime: '19:30',
        ),
        '507a0147474b': _entry(series: 'ドラゴンクエスト ダイの大冒険'),
      });

      final programs = await service.getProgram();
      expect(programs.values.map((p) => p.series).toList(), [
        '名探偵プリキュア！',
        'Yes！プリキュア5 鏡の国のミラクル大冒険',
        'わんだふるぷりきゅあ！',
        'ドラゴンクエスト ダイの大冒険',
      ]);
    });

    test('クライアントは並べ替えない（サーバーが崩した順もそのまま出る）', () async {
      // 5.32.0 より古いモロヘイヤは YAML 順で返す。ここで日付順に「直す」と
      // サーバー側の並び順の意図（毎日枠を末尾に送る等）を上書きしてしまう。
      final service = await _service({
        'c': _entry(series: 'C', nextOn: '2026-08-20', startTime: '01:00'),
        'a': _entry(series: 'A', nextOn: '2026-08-09', startTime: '08:30'),
        'b': _entry(series: 'B'),
      });

      final programs = await service.getProgram();
      expect(programs.values.map((p) => p.series).toList(), ['C', 'A', 'B']);
    });

    test('enable=false を除いても残りの順序は変わらない', () async {
      final service = await _service({
        'a': _entry(series: 'A', nextOn: '2026-08-09'),
        'b': _entry(series: 'B', nextOn: '2026-08-10', enable: false),
        'c': _entry(series: 'C', nextOn: '2026-08-11'),
      });

      final programs = await service.getProgram();
      expect(programs.values.map((p) => p.series).toList(), ['A', 'C']);
    });
  });

  group('start_time / next_on のパース (#965)', () {
    test('正常値を読む', () async {
      final service = await _service({
        'a': _entry(series: 'A', nextOn: '2026-08-09', startTime: '08:30'),
      });
      final p = (await service.getProgram()).values.single;
      expect(p.nextOn, DateTime(2026, 8, 9));
      expect(p.startTime, '08:30');
    });

    test('毎日枠は nextOn が null（値の欠落ではない）', () async {
      final service = await _service({'a': _entry(series: 'A')});
      final p = (await service.getProgram()).values.single;
      expect(p.nextOn, isNull);
      expect(p.startTime, isNull);
    });

    test('start_time は HH:MM へ正規化する', () {
      expect(parseProgramStartTime('9:00'), '09:00');
      expect(parseProgramStartTime('21:00'), '21:00');
      expect(parseProgramStartTime('00:00'), '00:00');
    });

    test('不正な start_time は null に倒す', () {
      expect(parseProgramStartTime('24:00'), isNull);
      expect(parseProgramStartTime('08:60'), isNull);
      expect(parseProgramStartTime('8時30分'), isNull);
      expect(parseProgramStartTime(''), isNull);
      expect(parseProgramStartTime(null), isNull);
      expect(parseProgramStartTime(830), isNull);
    });

    test('実在しない日付をロールオーバーさせない', () {
      // DateTime.parse は 2026-02-31 を 2026-03-03 に丸めてしまう。手編集由来の
      // 誤りが「それらしい別の日」として表示されるのを防ぐ。
      expect(parseProgramNextOn('2026-02-31'), isNull);
      expect(parseProgramNextOn('2026-13-01'), isNull);
      expect(parseProgramNextOn('2026-8-9'), isNull);
      expect(parseProgramNextOn('毎日'), isNull);
      expect(parseProgramNextOn(null), isNull);
      // 閏日は実在するので通す。
      expect(parseProgramNextOn('2028-02-29'), DateTime(2028, 2, 29));
    });
  });
}

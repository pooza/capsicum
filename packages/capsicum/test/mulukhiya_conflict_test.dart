import 'package:capsicum/src/ui/util/compose_template_display.dart';
import 'package:capsicum/src/util/mulukhiya_conflict.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1176: モロヘイヤ 5.38.0 の 409 の `code`（mulukhiya#4579）を読む。
///
/// ⚠⚠ **判定に `error` の文言を使わない。**文言は予告なく推敲される。
/// ⚠ **`code` の無い 409（5.37.x 以前・上流の 409 の透過）は従来どおり**
/// 「再試行は無駄」として扱う。
DioException _conflict({Object? body, Map<String, List<String>>? headers}) =>
    DioException(
      requestOptions: RequestOptions(path: '/x'),
      response: Response(
        requestOptions: RequestOptions(path: '/x'),
        statusCode: 409,
        data: body,
        headers: headers == null ? null : Headers.fromMap(headers),
      ),
    );

DioException _status(int code) => DioException(
  requestOptions: RequestOptions(path: '/x'),
  response: Response(
    requestOptions: RequestOptions(path: '/x'),
    statusCode: code,
  ),
);

void main() {
  group('mulukhiyaConflictCode', () {
    test('5 つの code を読む', () {
      const cases = {
        'locked': MulukhiyaConflict.locked,
        'auto_update': MulukhiyaConflict.autoUpdate,
        'duplicate_key': MulukhiyaConflict.duplicateKey,
        'template_limit': MulukhiyaConflict.templateLimit,
        'duplicate_request': MulukhiyaConflict.duplicateRequest,
      };
      for (final entry in cases.entries) {
        expect(
          mulukhiyaConflictCode(_conflict(body: {'code': entry.key})),
          entry.value,
          reason: entry.key,
        );
      }
    });

    test('⚠ code の無い 409 は null（5.37.x 以前・上流の透過）', () {
      expect(
        mulukhiyaConflictCode(_conflict(body: {'error': '上限に達しています'})),
        isNull,
      );
      expect(mulukhiyaConflictCode(_conflict(body: null)), isNull);
      // 上流の 409 がそのまま透過してボディが配列 / 文字列のこともある。
      expect(mulukhiyaConflictCode(_conflict(body: 'Conflict')), isNull);
      expect(mulukhiyaConflictCode(_conflict(body: <String>['x'])), isNull);
    });

    test('⚠ 未知の code は null（forward-compatible）', () {
      expect(
        mulukhiyaConflictCode(_conflict(body: {'code': 'future_code'})),
        isNull,
        reason: '⚠ 新しい版が足した code を古いクライアントが読んでも従来の扱いに落ちるだけ',
      );
    });

    test('⚠ 409 以外では code を読まない', () {
      for (final status in [200, 422, 429, 500]) {
        expect(
          mulukhiyaConflictCode(_status(status)),
          isNull,
          reason: '$status',
        );
      }
    });

    test('Dio 以外の例外は null', () {
      expect(mulukhiyaConflictCode(StateError('boom')), isNull);
    });

    test('⚠⚠ 文言では判定しない（同じ文言でも code が違えば別物）', () {
      final locked = _conflict(body: {'error': '別の更新が進行中です', 'code': 'locked'});
      final limit = _conflict(
        body: {'error': '別の更新が進行中です', 'code': 'template_limit'},
      );

      expect(mulukhiyaConflictCode(locked), MulukhiyaConflict.locked);
      expect(mulukhiyaConflictCode(limit), MulukhiyaConflict.templateLimit);
    });
  });

  group('mulukhiyaRetryAfterSeconds', () {
    test('locked の Retry-After を秒で読む', () {
      final e = _conflict(
        body: {'code': 'locked'},
        headers: {
          'retry-after': ['30'],
        },
      );

      expect(mulukhiyaRetryAfterSeconds(e), 30);
    });

    test('付いていなければ null / 数でなければ null', () {
      expect(
        mulukhiyaRetryAfterSeconds(_conflict(body: {'code': 'locked'})),
        isNull,
      );
      expect(
        mulukhiyaRetryAfterSeconds(
          _conflict(
            body: {'code': 'locked'},
            headers: {
              'retry-after': ['soon'],
            },
          ),
        ),
        isNull,
      );
    });
  });

  group('annictConflictMessage (#1176)', () {
    test('⚠⚠ duplicate_request は送り直しを促さない', () {
      final message = annictConflictMessage(MulukhiyaConflict.duplicateRequest);

      expect(message, contains('直前に同じ内容を送っています'));
      // ⚠ 「待って再試行」と促すと、先の要求が成功していた場合に二重に記録される。
      expect(message, isNot(contains('再試行')));
      expect(message, isNot(contains('もう一度')));
    });

    test('locked は再試行を促す（一過性なので待てば通る）', () {
      final message = annictConflictMessage(MulukhiyaConflict.locked);

      expect(message, contains('もう一度'));
    });

    test('code が無い / 別の code は従来の汎用文面', () {
      expect(annictConflictMessage(null), 'Annict への投稿に失敗しました');
      expect(
        annictConflictMessage(MulukhiyaConflict.autoUpdate),
        'Annict への投稿に失敗しました',
      );
    });
  });

  group('composeTemplateErrorMessage の 409 (#1176)', () {
    test('⚠⚠ ロックの競合を「上限」と出さない', () {
      final message = composeTemplateErrorMessage(
        _conflict(body: {'code': 'locked'}),
        fallback: 'だめでした',
      );

      expect(message, contains('もう一度'));
      expect(
        message,
        isNot(contains('上限')),
        reason: '⚠ 消しても直らない案内になる（ロックは一過性）',
      );
    });

    test('template_limit は上限の文面', () {
      final message = composeTemplateErrorMessage(
        _conflict(body: {'code': 'template_limit'}),
        fallback: 'だめでした',
      );

      expect(message, contains('上限'));
      expect(message, contains('$composeTemplateMaxCount'));
    });

    test('⚠ code の無い 409 は従来どおり上限の文面（5.37.x 以前）', () {
      final message = composeTemplateErrorMessage(
        _conflict(body: {'error': 'テンプレートが多すぎます'}),
        fallback: 'だめでした',
      );

      expect(message, contains('上限'));
    });

    test('前提: 409 以外の分岐は変えていない', () {
      expect(
        composeTemplateErrorMessage(_status(422), fallback: 'だめでした'),
        contains('入力内容が不正です'),
      );
      expect(
        composeTemplateErrorMessage(_status(404), fallback: 'だめでした'),
        contains('見つかりません'),
      );
      expect(
        composeTemplateErrorMessage(_status(500), fallback: 'だめでした'),
        'だめでした',
      );
    });
  });
}

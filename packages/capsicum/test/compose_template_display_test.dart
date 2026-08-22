import 'package:capsicum/src/ui/util/compose_template_display.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// #867: compose シートと管理画面で重複していたプレビュー整形・エラー文面を共通
/// ヘルパへ寄せた。両者で同じ分岐が効くことを純関数レベルで担保する。
void main() {
  ComposeTemplate t(String body) =>
      ComposeTemplate(id: 'x', name: 'n', body: body);

  DioException dioWith(int? status) => DioException(
    requestOptions: RequestOptions(path: '/compose/templates'),
    response: status == null
        ? null
        : Response(
            requestOptions: RequestOptions(path: '/compose/templates'),
            statusCode: status,
          ),
  );

  group('composeTemplateBodyPreview', () {
    test('空本文は（本文なし）。括弧は下書き側と揃えて全角 (#982)', () {
      expect(composeTemplateBodyPreview(t('')), '（本文なし）');
      expect(composeTemplateBodyPreview(t('   ')), '（本文なし）');
      expect(composeTemplateBodyPreview(t('\n\n')), '（本文なし）');
    });

    test('改行はスペースに畳んで 1 行にする', () {
      expect(composeTemplateBodyPreview(t('a\nb\nc')), 'a b c');
    });

    test('前後の空白は落とす', () {
      expect(composeTemplateBodyPreview(t('  hello  ')), 'hello');
    });
  });

  group('composeTemplateErrorMessage', () {
    test('409 は上限の案内（件数を含む）', () {
      final msg = composeTemplateErrorMessage(dioWith(409), fallback: 'fb');
      expect(msg, contains('上限'));
      expect(msg, contains('$composeTemplateMaxCount'));
    });

    test('422 は入力不正の案内', () {
      expect(
        composeTemplateErrorMessage(dioWith(422), fallback: 'fb'),
        contains('入力内容が不正'),
      );
    });

    test('404 は競合削除の案内', () {
      expect(
        composeTemplateErrorMessage(dioWith(404), fallback: 'fb'),
        contains('見つかりません'),
      );
    });

    test('その他ステータス・非 Dio 例外・response なしは fallback', () {
      expect(composeTemplateErrorMessage(dioWith(500), fallback: 'fb'), 'fb');
      expect(composeTemplateErrorMessage(dioWith(null), fallback: 'fb'), 'fb');
      expect(
        composeTemplateErrorMessage(Exception('boom'), fallback: 'fb'),
        'fb',
      );
    });
  });
}

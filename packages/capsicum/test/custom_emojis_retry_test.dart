import 'package:capsicum/src/provider/server_config_provider.dart';
import 'package:capsicum/src/util/login_error.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// #988 の回帰テスト。
///
/// **眼目は「一過性の失敗を抱え込まない」こと。** `customEmojisProvider` は素の
/// FutureProvider なので、一度 AsyncError になるとその状態を保持し続け、再評価の
/// 契機は `currentAdapterProvider` の変化（＝アカウント切替）しか無かった。回線が
/// 戻っても絵文字は戻らず、2026-08-18 のユーザー報告「しばらくすると復活する」の
/// 正体は、無関係なアカウントの復元完了で adapter が差し替わったタイミングだった。
///
/// 再取得の分岐そのものは provider の内側にあり、adapter を差し替えないと通せない。
/// ここでは**判定と刻みの性質**を固定して、次の 2 つの壊し方を検出する:
///
/// 1. 恒久失敗（4xx）まで再取得の対象に含める → 直らないものへ撃ち続ける
/// 2. 刻みを無制限・長大にする → 圏外のときに probe を撃ち続ける
void main() {
  final options = RequestOptions(path: '/api/emojis');

  group('再取得の対象 (#988)', () {
    test('接続断は対象（報告で観測された実際の失敗）', () {
      expect(
        classifyRestoreFailure(
          DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          ),
        ),
        RestoreOutcome.retriable,
      );
    });

    test('timeout も対象（絵文字一覧は重く、混雑時に伸びる）', () {
      expect(
        classifyRestoreFailure(
          DioException(
            requestOptions: options,
            type: DioExceptionType.receiveTimeout,
          ),
        ),
        RestoreOutcome.retriable,
      );
    });

    test('5xx も対象（サーバー再構築中など）', () {
      expect(
        classifyRestoreFailure(
          DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            response: Response<void>(requestOptions: options, statusCode: 503),
          ),
        ),
        RestoreOutcome.retriable,
      );
    });

    test('⚠ 4xx は対象外（待っても変わらないので即座に諦める）', () {
      expect(
        classifyRestoreFailure(
          DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            response: Response<void>(requestOptions: options, statusCode: 404),
          ),
        ),
        isNot(RestoreOutcome.retriable),
      );
    });
  });

  group('kCustomEmojiRetryDelays (#988)', () {
    test('⚠ 有限（圏外で撃ち続けない）', () {
      expect(kCustomEmojiRetryDelays, isNotEmpty);
      expect(kCustomEmojiRetryDelays.length, lessThanOrEqualTo(5));
    });

    test('刻みは伸びていく', () {
      for (var i = 1; i < kCustomEmojiRetryDelays.length; i++) {
        expect(
          kCustomEmojiRetryDelays[i] > kCustomEmojiRetryDelays[i - 1],
          isTrue,
          reason: '$i 番目が前より短い',
        );
      }
    });

    test('総待ち時間は 10 秒以内（ここで粘るのは復帰の受け皿の仕事）', () {
      final total = kCustomEmojiRetryDelays.reduce((a, b) => a + b);
      expect(
        total <= const Duration(seconds: 10),
        isTrue,
        reason: '長引かせるより retryCustomEmojisIfFailed（復帰契機）へ渡す',
      );
    });
  });
}

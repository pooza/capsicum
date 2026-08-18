import 'package:capsicum/src/provider/server_config_provider.dart';
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
    // 分類そのものの担保は test/util/login_error_test.dart。ここは
    // shouldRetryEmojiFetch が分類にどう乗るかだけを見る。
    test('接続断は対象（報告で観測された実際の失敗）', () {
      expect(
        shouldRetryEmojiFetch(
          DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          ),
        ),
        isTrue,
      );
    });

    test('5xx も対象（即座に返るうえ、再構築中なら復帰しうる）', () {
      expect(
        shouldRetryEmojiFetch(
          DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            response: Response<void>(requestOptions: options, statusCode: 503),
          ),
        ),
        isTrue,
      );
    });

    // ⚠ ここが #988 のリリース前レビューで見つかった退行。timeout を含めると
    // receiveTimeout 60 秒 × 4 回 ＝ 約 4 分 provider が AsyncLoading のままに
    // なり、Play は開始ゲートも再試行導線も出さないまま固まる（従来は約 1 分で
    // エラー面に到達していた）。isImmediateConnectFailure と判断軸を揃える。
    test('⚠ timeout は対象外（4 分スピナーを作らない）', () {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.sendTimeout,
      ]) {
        expect(
          shouldRetryEmojiFetch(
            DioException(requestOptions: options, type: type),
          ),
          isFalse,
          reason: '$type を再試行すると 60 秒待ちが積み上がる',
        );
      }
    });

    test('⚠ 4xx は対象外（待っても変わらない）', () {
      expect(
        shouldRetryEmojiFetch(
          DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            response: Response<void>(requestOptions: options, statusCode: 404),
          ),
        ),
        isFalse,
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

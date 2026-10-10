import 'package:capsicum/src/service/push_registration_status.dart';
import 'package:capsicum/src/service/push_relay_client.dart';
import 'package:capsicum/src/ui/widget/push_registration_status_section.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1237: relay の `/register` が返す 403 `entitlement_required` を読み分ける。
///
/// この経路に来るのは「利用権の記録は手元にあるが、relay が認めない（失効・
/// 未検証）」人。以前は一般の失敗と同じ「登録に失敗しました」で、同じ画面の
/// 利用権の節の説明と噛み合っていなかった。
void main() {
  DioException response(int status, Object? data) => DioException(
    requestOptions: RequestOptions(path: '/register'),
    type: DioExceptionType.badResponse,
    response: Response(
      requestOptions: RequestOptions(path: '/register'),
      statusCode: status,
      data: data,
    ),
  );

  group('PushRelayClient.isEntitlementRequired', () {
    test('403 かつ reason が entitlement_required のときだけ', () {
      expect(
        PushRelayClient.isEntitlementRequired(
          response(403, {
            'error': 'Entitlement required',
            'reason': 'entitlement_required',
          }),
        ),
        isTrue,
      );
    });

    test('⚠ ステータスだけでは決めない（別の理由の 403 を巻き込まない）', () {
      for (final data in <Object?>[
        null,
        'Forbidden',
        {'error': 'Forbidden'},
        {'reason': 'something_else'},
      ]) {
        expect(
          PushRelayClient.isEntitlementRequired(response(403, data)),
          isFalse,
          reason: '$data',
        );
      }
    });

    test('⚠ 401（シークレット違い）や 503 は別物', () {
      const body = {'reason': 'entitlement_required'};
      expect(
        PushRelayClient.isEntitlementRequired(response(401, body)),
        isFalse,
      );
      expect(
        PushRelayClient.isEntitlementRequired(response(503, body)),
        isFalse,
      );
    });

    test('応答の無い失敗・Dio 以外の例外は別物', () {
      expect(
        PushRelayClient.isEntitlementRequired(
          DioException(
            requestOptions: RequestOptions(path: '/register'),
            type: DioExceptionType.connectionTimeout,
          ),
        ),
        isFalse,
      );
      expect(PushRelayClient.isEntitlementRequired(StateError('x')), isFalse);
    });
  });

  // #1237: 「relay に届かなかっただけの回は Sentry へ送らない」の判定が、
  // 応答が無いものを全部握っていた（証明書の事故まで黙る）。
  group('PushRelayClient.isUnreachable', () {
    DioException noResponse(DioExceptionType type) => DioException(
      requestOptions: RequestOptions(path: '/entitlements'),
      type: type,
    );

    test('圏外・時間切れは「届かなかった」', () {
      for (final type in [
        DioExceptionType.connectionError,
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.unknown,
      ]) {
        expect(
          PushRelayClient.isUnreachable(noResponse(type)),
          isTrue,
          reason: type.name,
        );
      }
    });

    test('⚠⚠ 証明書の失敗は「届かなかった」に数えない（黙らせない）', () {
      expect(
        PushRelayClient.isUnreachable(
          noResponse(DioExceptionType.badCertificate),
        ),
        isFalse,
      );
    });

    test('応答が返っている回・Dio 以外は別物', () {
      expect(PushRelayClient.isUnreachable(response(500, null)), isFalse);
      expect(PushRelayClient.isUnreachable(response(401, null)), isFalse);
      expect(PushRelayClient.isUnreachable(StateError('x')), isFalse);
    });
  });

  // #1237: relay の `Retry-After` を読んでいなかった。
  group('PushRelayClient.retryDelayFor', () {
    DioException busy(String? retryAfter) => DioException(
      requestOptions: RequestOptions(path: '/entitlements'),
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: RequestOptions(path: '/entitlements'),
        statusCode: 503,
        headers: Headers.fromMap({
          if (retryAfter != null) 'retry-after': [retryAfter],
        }),
      ),
    );

    test('ヘッダが無ければ既定の間隔（2 → 5 → 15 秒）', () {
      expect(
        [
          for (var i = 0; i < 3; i++)
            PushRelayClient.retryDelayFor(busy(null), i).inSeconds,
        ],
        [2, 5, 15],
      );
    });

    test('⚠ relay が既定より長く指定したら、そちらに従う', () {
      expect(PushRelayClient.retryDelayFor(busy('10'), 0).inSeconds, 10);
    });

    test('⚠ 短くはしない（既定のほうが長ければ既定）', () {
      expect(PushRelayClient.retryDelayFor(busy('2'), 0).inSeconds, 2);
      expect(PushRelayClient.retryDelayFor(busy('1'), 1).inSeconds, 5);
    });

    test('⚠ 上限を超える値・読めない値で画面を止めない', () {
      expect(PushRelayClient.retryDelayFor(busy('3600'), 0).inSeconds, 30);
      for (final raw in [
        '',
        'soon',
        '-5',
        '0',
        'Wed, 21 Oct 2026 07:28:00 GMT',
      ]) {
        expect(
          PushRelayClient.retryDelayFor(busy(raw), 0).inSeconds,
          2,
          reason: raw,
        );
      }
    });
  });

  group('登録状況の行の文面', () {
    String text(PushRegistrationFailureReason? reason) =>
        describePushRegistrationStatus(
          ThemeData(),
          PushRegistrationState.failed,
          true,
          reason,
        ).$1;

    test('⚠ 利用権を認められなかった回は、利用権の話として出す', () {
      expect(
        text(PushRegistrationFailureReason.entitlementRejected),
        'プッシュ通知リレーの利用権を確認できませんでした',
      );
    });

    test('前提: ほかの失敗は従来どおり', () {
      expect(text(PushRegistrationFailureReason.relayFailed), '登録に失敗しました');
      expect(text(PushRegistrationFailureReason.subscribeFailed), '登録に失敗しました');
      expect(text(null), '登録に失敗しました');
      expect(
        text(PushRegistrationFailureReason.permissionDenied),
        '通知の権限が許可されていません',
      );
    });
  });
}

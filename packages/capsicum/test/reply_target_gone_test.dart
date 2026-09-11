import 'package:capsicum/src/util/reply_target_gone.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1113: 投稿の失敗が「返信先の投稿が消えている」ためかを見分ける。
///
/// 再編集で引き継いだ返信先が消えていると、サーバーは送信を拒否する。見分けて
/// 「返信をやめれば送れる」と案内する。⚠ 見分けを誤ると、返信をやめても送れない
/// 案内になるので、**決めつけない側**へ倒すことも固定する。
void main() {
  DioException error(int status, [Object? data]) {
    final options = RequestOptions(path: '/');
    return DioException(
      requestOptions: options,
      response: Response(
        requestOptions: options,
        statusCode: status,
        data: data,
      ),
    );
  }

  Map<String, dynamic> misskey(String code) => {
    'error': {'code': code, 'message': 'x', 'id': 'x'},
  };

  bool gone(Object e, {bool sentAsReply = true, bool sentWithQuote = false}) =>
      isReplyTargetGoneError(
        e,
        sentAsReply: sentAsReply,
        sentWithQuote: sentWithQuote,
      );

  group('Misskey', () {
    test('NO_SUCH_REPLY_TARGET なら返信先の消失', () {
      expect(gone(error(400, misskey('NO_SUCH_REPLY_TARGET'))), isTrue);
    });

    test('⚠ 引用付きでもコードで区別できるので決まる', () {
      expect(
        gone(error(400, misskey('NO_SUCH_REPLY_TARGET')), sentWithQuote: true),
        isTrue,
      );
    });

    test('ほかのコード（引用元の消失など）は違う', () {
      expect(gone(error(400, misskey('NO_SUCH_RENOTE_TARGET'))), isFalse);
      expect(gone(error(400, misskey('RATE_LIMIT_EXCEEDED'))), isFalse);
    });
  });

  group('Mastodon', () {
    test('返信として送った 404 は返信先の消失', () {
      expect(
        gone(error(404, {'error': 'あなたが返信しようとしている投稿は存在しないようです。'})),
        isTrue,
      );
    });

    test('⚠⚠ 引用付きの 404 は決めつけない（引用元の消失と区別できない）', () {
      expect(gone(error(404, {'error': 'x'}), sentWithQuote: true), isFalse);
    });

    test('404 以外は違う', () {
      expect(gone(error(422, {'error': 'x'})), isFalse);
      expect(gone(error(500)), isFalse);
    });
  });

  test('返信として送っていなければ違う', () {
    expect(
      gone(error(400, misskey('NO_SUCH_REPLY_TARGET')), sentAsReply: false),
      isFalse,
    );
    expect(gone(error(404), sentAsReply: false), isFalse);
  });

  test('通信の例外でなければ違う', () {
    expect(gone(Exception('x')), isFalse);
  });
}

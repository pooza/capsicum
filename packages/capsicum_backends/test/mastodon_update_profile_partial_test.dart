import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #806 item 1: プロフィール更新の部分成功。
///
/// Mastodon は本文更新（PATCH update_credentials）と画像削除（4.6 の
/// DELETE profile/{avatar,header}）が別リクエストで、本文成功後に削除だけ
/// 失敗しても本文はサーバーに保存済みになる。updateProfile がこれを
/// [ProfileUpdatePartialException] として返し、全失敗にしないことを検証する。
class _RoutingAdapter implements HttpClientAdapter {
  /// path substring -> (status, jsonBody)
  _RoutingAdapter(this.routes);

  final List<({String match, int status, Object body})> routes;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    for (final r in routes) {
      if (options.path.contains(r.match)) {
        return ResponseBody.fromString(
          r.body is String ? r.body as String : jsonEncode(r.body),
          r.status,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      }
    }
    return ResponseBody.fromString('{}', 404);
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _account({String display = 'capsicum'}) => {
  'id': '1',
  'username': 'capsicum',
  'acct': 'capsicum',
  'display_name': display,
  'note': '',
  'avatar': '',
  'header': '',
  'followers_count': 0,
  'following_count': 0,
  'statuses_count': 0,
  'fields': <Map<String, dynamic>>[],
};

Future<MastodonAdapter> _adapterWith(
  List<({String match, int status, Object body})> routes,
) async {
  final adapter = await MastodonAdapter.create('example.com');
  adapter.client.dio.httpClientAdapter = _RoutingAdapter(routes);
  return adapter;
}

void main() {
  group('MastodonAdapter.updateProfile — 部分成功', () {
    test('本文成功・アバター削除失敗は ProfileUpdatePartialException', () async {
      final adapter = await _adapterWith([
        (match: 'update_credentials', status: 200, body: _account()),
        (match: 'profile/avatar', status: 500, body: {'error': 'boom'}),
      ]);

      await expectLater(
        adapter.updateProfile(displayName: '更新後', removeAvatar: true),
        throwsA(
          isA<ProfileUpdatePartialException>()
              .having((e) => e.avatarRemoveFailed, 'avatarRemoveFailed', isTrue)
              .having(
                (e) => e.headerRemoveFailed,
                'headerRemoveFailed',
                isFalse,
              )
              .having((e) => e.user.id, 'user.id', '1'),
        ),
      );
    });

    test('本文・ヘッダー削除の両方成功なら例外は投げない', () async {
      final adapter = await _adapterWith([
        (match: 'update_credentials', status: 200, body: _account()),
        (match: 'profile/header', status: 200, body: _account()),
      ]);

      final user = await adapter.updateProfile(
        displayName: '更新後',
        removeHeader: true,
      );
      expect(user.id, '1');
    });

    test('本文更新そのものの失敗は部分成功でなく通常の失敗として伝播する', () async {
      final adapter = await _adapterWith([
        (match: 'update_credentials', status: 422, body: {'error': 'bad'}),
      ]);

      await expectLater(
        adapter.updateProfile(displayName: '更新後', removeAvatar: true),
        throwsA(
          allOf(
            isA<DioException>(),
            isNot(isA<ProfileUpdatePartialException>()),
          ),
        ),
      );
    });

    test('アバター・ヘッダー削除の両方失敗は failedSteps に両方載る', () async {
      final adapter = await _adapterWith([
        (match: 'update_credentials', status: 200, body: _account()),
        (match: 'profile/avatar', status: 500, body: {'error': 'boom'}),
        (match: 'profile/header', status: 500, body: {'error': 'boom'}),
      ]);

      await expectLater(
        adapter.updateProfile(removeAvatar: true, removeHeader: true),
        throwsA(
          isA<ProfileUpdatePartialException>()
              .having((e) => e.avatarRemoveFailed, 'avatarRemoveFailed', isTrue)
              .having(
                (e) => e.headerRemoveFailed,
                'headerRemoveFailed',
                isTrue,
              ),
        ),
      );
    });
  });
}

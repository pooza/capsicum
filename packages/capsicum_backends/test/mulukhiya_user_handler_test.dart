import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1398: 利用者が自分の投稿に効くモロヘイヤのハンドラーを切り替える
/// （mulukhiya#4195 / #4196・入口のフラグは mulukhiya#4936）。
class _Adapter implements HttpClientAdapter {
  _Adapter({this.flag, this.configStatus = 200});

  /// `features.user_handler_config`。null なら features に載せない（旧版）。
  final bool? flag;
  final int configStatus;

  RequestOptions? listRequest;
  RequestOptions? configRequest;
  Map<String, dynamic>? configBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path.endsWith('/handler/list')) {
      listRequest = options;
      return _json([
        {
          'name': 'default_tag',
          'label': 'デフォルトタグ',
          'description': '投稿にデフォルトのハッシュタグを付与します',
          'toggleable': false,
          'disabled': false,
        },
        {
          'name': 'url_normalize',
          'label': null,
          'description': '',
          'toggleable': true,
          'disabled': true,
        },
        // 名前の無いものは落とす。
        {'name': '', 'toggleable': true, 'disabled': false},
      ], 200);
    }
    if (path.endsWith('/handler/config')) {
      configRequest = options;
      if (requestStream != null) {
        final bytes = (await requestStream.toList()).expand((c) => c).toList();
        configBody = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      }
      return _json({
        'name': configBody?['handler'],
        'disabled': configBody?['disable'],
      }, configStatus);
    }
    return _json({
      'package': {'version': '5.49.0'},
      'config': {
        'controller': 'mastodon',
        'features': {'user_handler_config': ?flag},
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

Future<({MulukhiyaService service, _Adapter http})> _build({
  bool? flag = true,
  int configStatus = 200,
}) async {
  final http = _Adapter(flag: flag, configStatus: configStatus);
  final dio = Dio()..httpClientAdapter = http;
  final service = await MulukhiyaService.detect(dio, 'h.example');
  return (service: service!, http: http);
}

void main() {
  group('features.user_handler_config', () {
    test('true なら入口を出せる', () async {
      expect((await _build()).service.userHandlerConfigEnabled, isTrue);
    });

    test('⚠ 載っていない（旧版）なら false に倒す', () async {
      expect(
        (await _build(flag: null)).service.userHandlerConfigEnabled,
        isFalse,
      );
    });
  });

  group('getUserHandlers', () {
    test('bearer を付けて一覧を取り、項目を読む', () async {
      final built = await _build();
      final handlers = await built.service.getUserHandlers(accessToken: 'tok');

      expect(built.http.listRequest?.headers['Authorization'], 'Bearer tok');
      expect(handlers.map((h) => h.name), ['default_tag', 'url_normalize']);
      final tag = handlers.first;
      expect(tag.label, 'デフォルトタグ');
      expect(tag.toggleable, isFalse);
      expect(tag.disabled, isFalse);
      // label / description が null・空なら null。
      final url = handlers.last;
      expect(url.label, isNull);
      expect(url.description, isNull);
      expect(url.toggleable, isTrue);
      expect(url.disabled, isTrue);
    });
  });

  group('setUserHandlerDisabled', () {
    test('handler と disable（真偽値）を送り、切り替えたあとの値を返す', () async {
      final built = await _build();
      final disabled = await built.service.setUserHandlerDisabled(
        accessToken: 'tok',
        handler: 'url_normalize',
        disabled: false,
      );

      expect(built.http.configRequest?.method, 'POST');
      expect(built.http.configRequest?.headers['Authorization'], 'Bearer tok');
      expect(built.http.configBody, {
        'handler': 'url_normalize',
        'disable': false,
      });
      expect(disabled, isFalse);
    });

    test('切り替えられないもの（422）は投げる', () async {
      final built = await _build(configStatus: 422);
      await expectLater(
        built.service.setUserHandlerDisabled(
          accessToken: 'tok',
          handler: 'default_tag',
          disabled: true,
        ),
        throwsA(isA<DioException>()),
      );
    });
  });

  test('MulukhiyaUserHandler.copyWith は disabled だけを変える', () {
    const h = MulukhiyaUserHandler(
      name: 'a',
      label: 'A',
      toggleable: true,
      disabled: false,
    );
    final next = h.copyWith(disabled: true);
    expect(next.disabled, isTrue);
    expect(next.name, 'a');
    expect(next.label, 'A');
  });
}

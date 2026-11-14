import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1287: `api/v2/filters` が無いサーバー（Akkoma などの Pleroma 系）では
/// [FiltersUnavailable] を投げる。⚠ 404 以外は失敗のまま上げる。
class _StatusAdapter implements HttpClientAdapter {
  _StatusAdapter(this.status);

  final int status;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      status == 200 ? '[]' : '{"error":"x"}',
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  Future<MastodonAdapter> adapterWith(int status) async {
    final adapter = await MastodonAdapter.create('akkoma.example');
    adapter.client.dio.httpClientAdapter = _StatusAdapter(status);
    return adapter;
  }

  test('404 は FiltersUnavailable（口が無い）', () async {
    final adapter = await adapterWith(404);
    expect(adapter.getFilters(), throwsA(isA<FiltersUnavailable>()));
  });

  test('⚠ 500 は失敗のまま（使えないと取り違えない）', () async {
    final adapter = await adapterWith(500);
    expect(adapter.getFilters(), throwsA(isA<DioException>()));
  });

  test('⚠ 401 も失敗のまま', () async {
    final adapter = await adapterWith(401);
    expect(adapter.getFilters(), throwsA(isA<DioException>()));
  });

  test('200 なら一覧', () async {
    final adapter = await adapterWith(200);
    expect(await adapter.getFilters(), isEmpty);
  });
}

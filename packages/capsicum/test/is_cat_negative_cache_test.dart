import 'package:capsicum/src/provider/is_cat_provider.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1080 の回帰テスト。
///
/// ⚠ **守りたいのは「一度失敗した acct を毎回引きに行かない」こと。**
/// モロヘイヤの `/account/is_cat` はキャッシュに無い acct をその場でリモートへ
/// 取りに行き、**失敗をサーバー側にキャッシュしない**（mulukhiya#4677）。
/// 到達不能なサーバーのアカウントは通知欄に何か月も残るので、クライアント側で
/// 覚えておかないと、その通知が流れるまで毎回タイムアウトを払い続ける。

/// `fetchIsCat` の呼び出し回数と引数を数えるだけのスタブ。
///
/// ⚠ **実サーバーに依存させない。**外部サーバーの生死は制御できないので、
/// 実再現に頼ると次に同じ調査からやり直しになる。
class _CountingMulukhiya implements MulukhiyaService {
  final List<List<String>> calls = [];

  /// 返す値。null なら「リクエストごと失敗」を表す。
  Map<String, bool?>? response;

  _CountingMulukhiya({this.response});

  @override
  Future<Map<String, bool?>?> fetchIsCat({
    required String accessToken,
    required List<String> accts,
  }) async {
    calls.add(List.of(accts));
    return response;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

User _user(String username, String host) =>
    User(id: username, username: username, host: host);

void main() {
  setUp(IsCatEnricher.resetCachesForTest);

  group('IsCatEnricher のネガティブキャッシュ (#1080)', () {
    test('リクエストごと失敗した acct は再問い合わせしない', () async {
      final mulukhiya = _CountingMulukhiya();
      final enricher = IsCatEnricher(
        mulukhiya: mulukhiya,
        accessToken: 'token',
      );
      final users = [_user('someone', 'unreachable.example')];

      await enricher.enrichUsers(users);
      expect(mulukhiya.calls, hasLength(1));

      // 2 回目は問い合わせ自体が起きない。
      await enricher.enrichUsers(users);
      expect(mulukhiya.calls, hasLength(1));
    });

    test('個別に解決できなかった acct も再問い合わせしない', () async {
      final mulukhiya = _CountingMulukhiya(
        response: {'someone@unreachable.example': null},
      );
      final enricher = IsCatEnricher(
        mulukhiya: mulukhiya,
        accessToken: 'token',
      );
      final users = [_user('someone', 'unreachable.example')];

      await enricher.enrichUsers(users);
      await enricher.enrichUsers(users);

      // サーバーは 200 を返しているが、値が null＝解決できていない。
      expect(mulukhiya.calls, hasLength(1));
    });

    test('解決できた acct は通常のキャッシュに乗り、再問い合わせしない', () async {
      final mulukhiya = _CountingMulukhiya(
        response: {'nyan@example.com': true},
      );
      final enricher = IsCatEnricher(
        mulukhiya: mulukhiya,
        accessToken: 'token',
      );
      final users = [_user('nyan', 'example.com')];

      final first = await enricher.enrichUsers(users);
      expect(first.single.isCat, isTrue);

      final second = await enricher.enrichUsers(users);
      expect(second.single.isCat, isTrue);
      expect(mulukhiya.calls, hasLength(1));
    });

    test('失敗した acct が混ざっても、他の acct の問い合わせは止めない', () async {
      final mulukhiya = _CountingMulukhiya(
        response: {'dead@unreachable.example': null},
      );
      final enricher = IsCatEnricher(
        mulukhiya: mulukhiya,
        accessToken: 'token',
      );

      await enricher.enrichUsers([_user('dead', 'unreachable.example')]);
      expect(mulukhiya.calls, hasLength(1));

      // 別の acct はネガティブキャッシュに載っていないので問い合わせる。
      mulukhiya.response = {'nyan@example.com': true};
      final result = await enricher.enrichUsers([_user('nyan', 'example.com')]);

      expect(mulukhiya.calls, hasLength(2));
      expect(mulukhiya.calls.last, ['nyan@example.com']);
      expect(result.single.isCat, isTrue);
    });

    test('通信例外もネガティブキャッシュに載る', () async {
      final mulukhiya = _ThrowingMulukhiya();
      final enricher = IsCatEnricher(
        mulukhiya: mulukhiya,
        accessToken: 'token',
      );
      final users = [_user('someone', 'unreachable.example')];

      await enricher.enrichUsers(users);
      await enricher.enrichUsers(users);

      expect(mulukhiya.callCount, 1);
    });
  });

  group('kIsCatEnrichBudget', () {
    test('is_cat 自体のタイムアウト（5 秒）より短い', () {
      // 呼び出し元の待ち上限がリクエストのタイムアウトより長いと、
      // 「装飾のために本体を止めない」という趣旨が成立しない。
      expect(kIsCatEnrichBudget, lessThan(const Duration(seconds: 5)));
    });
  });
}

class _ThrowingMulukhiya implements MulukhiyaService {
  int callCount = 0;

  @override
  Future<Map<String, bool?>?> fetchIsCat({
    required String accessToken,
    required List<String> accts,
  }) async {
    callCount++;
    throw DioException.connectionTimeout(
      timeout: const Duration(seconds: 5),
      requestOptions: RequestOptions(path: '/account/is_cat'),
    );
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

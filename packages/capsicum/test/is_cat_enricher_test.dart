import 'dart:io';

import 'package:capsicum/src/provider/is_cat_provider.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1082（実装の一本化）と #1083-C（観測性）の回帰テスト。
///
/// ## なぜ要るか
///
/// ⚠⚠ **isCat の解決とキャッシュは 2 系統あった。**`IsCatEnricher` と
/// `TimelineNotifier._enrichIsCat` が別々のキャッシュと別々の実装を持ち、
/// **#1080 で入れたネガティブキャッシュが timeline に効いていなかった**。
/// #1080 自体が「片方だけ直した」事故だったので、**寄せたことが戻らないよう
/// 押さえる**。
///
/// ⚠⚠ **観測は「壊れても誰も気づかない」種類。**#1080 の調査で長時間かかった
/// 理由が「握りつぶしのせいで Sentry に一切出ない」ことだったのに、その盲点は
/// 塞がっていなかった。しかも **#1080 でネガティブキャッシュを入れたぶん、
/// 「毎回遅い」という症状すら出なくなった**ので、気づける経路がここしかない。
/// だから **判定（閾値・レート制限・個別失敗を数えないこと）を固定する。**
class _ScriptedMulukhiya implements MulukhiyaService {
  /// 呼ばれた回数ぶん、先頭から順に返す。尽きたら最後の値を返し続ける。
  final List<Map<String, bool?>?> responses;
  final List<List<String>> calls = [];

  @override
  final String baseUrl;

  _ScriptedMulukhiya({
    required this.responses,
    this.baseUrl = 'https://mulukhiya.example.test/api',
  });

  @override
  Future<Map<String, bool?>?> fetchIsCat({
    required String accessToken,
    required List<String> accts,
  }) async {
    calls.add(List.of(accts));
    final i = calls.length - 1;
    return i < responses.length ? responses[i] : responses.last;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

User _user(String username, String host) =>
    User(id: username, username: username, host: host);

Post _post(User author) => Post(
  id: 'post-${author.username}',
  author: author,
  content: 'x',
  postedAt: DateTime.utc(2026),
);

void main() {
  setUp(IsCatEnricher.resetCachesForTest);
  tearDown(IsCatEnricher.resetCachesForTest);

  IsCatEnricher enricherFor(MulukhiyaService m) =>
      IsCatEnricher(mulukhiya: m, accessToken: 'token');

  group('キャッシュの一本化 (#1082)', () {
    test('別インスタンスでもプロセス共有のキャッシュを使う', () async {
      // ⚠ **これが timeline / 通知で別々に引かれていた形。**timeline が独自の
      // インスタンスキャッシュを持っていたので、片方で解決済みの acct を
      // もう片方がもう一度引いていた。
      final mulukhiya = _ScriptedMulukhiya(
        responses: [
          {'nyan@remote.example': true},
        ],
      );
      final users = [_user('nyan', 'remote.example')];

      await enricherFor(mulukhiya).enrichUsers(users);
      // 別インスタンス（＝ timeline 相当の経路）から同じ acct を引く。
      final posts = await enricherFor(mulukhiya).enrichPosts([_post(users[0])]);

      expect(mulukhiya.calls.length, 1, reason: '2 回目は問い合わせない');
      expect(posts.single.author.isCat, isTrue);
    });

    test('投稿経路でもネガティブキャッシュが効く', () async {
      // ⚠ **#1082 の本丸。**timeline の独自実装は #1080 のネガティブキャッシュを
      // 持っていなかったので、解決できない acct を毎回引きに行っていた。
      final mulukhiya = _ScriptedMulukhiya(
        responses: [
          {'ghost@unreachable.example': null},
        ],
      );
      final posts = [_post(_user('ghost', 'unreachable.example'))];
      final enricher = enricherFor(mulukhiya);

      await enricher.enrichPosts(posts);
      await enricher.enrichPosts(posts);

      expect(
        mulukhiya.calls.length,
        1,
        reason: '個別に解決できなかった acct は 30 分引きに行かない (#1080)',
      );
    });

    test('applyCachedToPosts は問い合わせずキャッシュだけで塗る', () async {
      // timeline の「キャッシュ温め → 最新 state へ再適用」経路。
      final mulukhiya = _ScriptedMulukhiya(
        responses: [
          {'nyan@remote.example': true},
        ],
      );
      final enricher = enricherFor(mulukhiya);
      final author = _user('nyan', 'remote.example');

      await enricher.enrichPosts([_post(author)]);
      expect(mulukhiya.calls.length, 1);

      // 温めたあとに現れた別の投稿（同じ著者）を、取得なしで塗る。
      final reapplied = enricher.applyCachedToPosts([_post(author)]);

      expect(mulukhiya.calls.length, 1, reason: '再適用で問い合わせない');
      expect(reapplied.single.author.isCat, isTrue);
    });

    test('キャッシュが空なら applyCachedToPosts は素通し', () {
      final posts = [_post(_user('plain', 'remote.example'))];
      expect(
        identical(
          enricherFor(
            _ScriptedMulukhiya(responses: [null]),
          ).applyCachedToPosts(posts),
          posts,
        ),
        isTrue,
      );
    });
  });

  /// ⚠⚠ **上のテストは「enricher が正しいこと」しか見ていない。**
  /// #1082 の失敗モードは「**timeline がまた独自実装を持つ**」なので、
  /// 振る舞いのテストでは検出できない。ソースで押さえる。
  group('一本化が戻らないこと（ソース検査・#1082 / #1083-C）', () {
    String sourceOf(String path) => maskComments(File(path).readAsStringSync());

    const timelinePath = 'lib/src/provider/timeline_provider.dart';
    const enricherPath = 'lib/src/provider/is_cat_provider.dart';

    test('timeline が独自の isCat 実装を持ち直していない', () {
      final source = sourceOf(timelinePath);
      expect(
        source,
        contains('applyCachedToPosts'),
        reason: '寄せ先を使っていない。検査のアンカーが外れた可能性もある',
      );
      expect(
        source,
        isNot(contains('_isCatCache')),
        reason:
            'timeline が独自キャッシュを持ち直している (#1082)。'
            '#1080 のネガティブキャッシュがそちらに効かない',
      );
      expect(
        source,
        isNot(contains('fetchIsCat')),
        reason:
            'timeline が /account/is_cat を直に叩いている (#1082)。'
            'IsCatEnricher を通すこと',
      );
    });

    test('待ち上限を掛けるのは enricher の中だけ (#1083-C)', () {
      // ⚠ **超過の計装は 1 箇所にある。**呼び出し側で `.timeout` を掛け直すと、
      // そこの超過は誰にも見えないまま戻る（塞いだ穴そのもの）。
      final offenders = <String>[];
      for (final file
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        if (file.path == enricherPath) continue;
        if (sourceOf(file.path).contains('kIsCatEnrichBudget')) {
          offenders.add(file.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            '待ち上限は IsCatEnricher の中で掛かる (#1083-C)。'
            '呼び出し側で掛け直すと超過が計装されない'
            '\n${offenders.join('\n')}',
      );
    });

    test('検査が実際にソースを読んでいる', () {
      // 「contains しない」ばかりの検査は、パスが変わると全部緑になる。
      expect(File(timelinePath).existsSync(), isTrue);
      expect(sourceOf(enricherPath), contains('kIsCatEnrichBudget'));
    });
  });

  group('outage の観測 (#1083-C)', () {
    late List<({String host, int streak})> reports;

    setUp(() {
      reports = [];
      isCatOutageReporter = (host, streak) =>
          reports.add((host: host, streak: streak));
    });

    /// リクエスト全体の失敗（`fetchIsCat` が null）を [times] 回起こす。
    /// ⚠ **毎回別の acct を使う。**同じ acct だと 2 回目以降は
    /// 「キャッシュに無いが問い合わせ対象」ではなくなる…わけではないが、
    /// ネガティブキャッシュの影響を受けないよう分けておく。
    Future<void> failTimes(IsCatEnricher enricher, int times) async {
      for (var i = 0; i < times; i++) {
        await enricher.enrichUsers([_user('u$i', 'remote.example')]);
      }
    }

    test('1 回の失敗では上げない', () async {
      final enricher = enricherFor(_ScriptedMulukhiya(responses: [null]));
      await failTimes(enricher, 1);
      expect(reports, isEmpty, reason: '通信断や一過性の 504 は日常的に起きる');
    });

    test('連続失敗が閾値に届いたら 1 件だけ上げる', () async {
      final mulukhiya = _ScriptedMulukhiya(responses: [null]);
      await failTimes(enricherFor(mulukhiya), 8);

      expect(reports.length, 1, reason: 'レート制限が効いて 1 件だけ');
      expect(reports.single.host, 'mulukhiya.example.test');
      expect(reports.single.streak, greaterThanOrEqualTo(5));
    });

    test('途中で成功したら連続失敗はリセットされる', () async {
      // ⚠ 4 回失敗 → 1 回成功 → 4 回失敗。通しでは 8 回失敗しているが、
      // **連続していない**ので「機能が死んでいる」ではない。
      final mulukhiya = _ScriptedMulukhiya(
        responses: [
          null,
          null,
          null,
          null,
          <String, bool?>{},
          null,
          null,
          null,
          null,
        ],
      );
      final enricher = enricherFor(mulukhiya);
      await failTimes(enricher, 9);

      expect(reports, isEmpty);
    });

    test('⚠ 個別 acct の解決失敗は数えない', () async {
      // ⚠⚠ **ここが #1083-C の肝。**リモートを引けないアカウントは日常的に
      // あり、猫耳が付かないだけの装飾。数えると母数がそれで埋まって、
      // 見たいもの（機能そのものが死んでいる）が沈む。
      final mulukhiya = _ScriptedMulukhiya(
        responses: [
          for (var i = 0; i < 9; i++) {'u$i@remote.example': null},
        ],
      );
      await failTimes(enricherFor(mulukhiya), 9);

      expect(reports, isEmpty, reason: '個別失敗はネガティブキャッシュの担当。outage ではない');
    });

    test('例外でも「リクエスト全体の失敗」として数える', () async {
      // ⚠ 握りつぶすのは正しい（その acct が解決できないとは限らない）が、
      // **握りつぶしたことは数える。**
      final enricher = enricherFor(_ThrowingMulukhiya());
      await failTimes(enricher, 8);
      expect(reports.length, 1);
    });

    test('モロヘイヤごとに別々に数える', () async {
      // ⚠ アカウント B のモロヘイヤが落ちていても、健全な A の判定に混ぜない
      // （[_failureKey] が baseUrl で名前空間を切っているのと同じ理由）。
      final downA = _ScriptedMulukhiya(
        responses: [null],
        baseUrl: 'https://a.example.test/api',
      );
      final downB = _ScriptedMulukhiya(
        responses: [null],
        baseUrl: 'https://b.example.test/api',
      );
      await failTimes(enricherFor(downA), 4);
      await failTimes(enricherFor(downB), 4);

      expect(reports, isEmpty, reason: 'どちらも閾値に届いていない');
    });
  });
}

class _ThrowingMulukhiya implements MulukhiyaService {
  @override
  final String baseUrl = 'https://mulukhiya.example.test/api';

  @override
  Future<Map<String, bool?>?> fetchIsCat({
    required String accessToken,
    required List<String> accts,
  }) async => throw StateError('boom');

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

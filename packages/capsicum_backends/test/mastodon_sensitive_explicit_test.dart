import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1194: 閲覧注意の `false` を明示して送れるようにする。
///
/// ⚠⚠ **Mastodon は `sensitive` を省くとサーバー既定（`source.sensitive`）を
/// 当てる。**したがって `false` を送らないと、**既定が true の利用者は capsicum
/// から閲覧注意を外せない**（トグルが嘘になる）。
///
/// ⚠ **常に送る形にはできない。**`source` を返さない / 既定を持たないサーバーでは、
/// いままで効いていた「サーバー既定に任せる」が壊れる。**既定を読めたか、利用者が
/// 自分で切り替えたときだけ**明示する（`PostDraft.sensitiveExplicit`）。
class _CapturingAdapter implements HttpClientAdapter {
  Map<String, dynamic>? lastBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastBody = options.data as Map<String, dynamic>?;
    return ResponseBody.fromString(
      '{"id":"1","created_at":"2026-10-01T00:00:00.000Z","content":"",'
      '"account":{"id":"1","username":"u","acct":"u","display_name":"u",'
      '"note":"","avatar":"","header":"","followers_count":0,'
      '"following_count":0,"statuses_count":0,"fields":[]},'
      '"visibility":"public","media_attachments":[],"mentions":[],"tags":[],'
      '"emojis":[]}',
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _CapturingAdapter http;
  late MastodonAdapter adapter;

  setUp(() async {
    http = _CapturingAdapter();
    adapter = await MastodonAdapter.create('example.com');
    adapter.client.dio.httpClientAdapter = http;
    await adapter.applySecrets(null, const UserSecret(accessToken: 't'));
  });

  PostDraft draft({required bool sensitive, required bool explicit}) =>
      PostDraft(
        content: 'やあ',
        scope: PostScope.public,
        sensitive: sensitive,
        sensitiveExplicit: explicit,
      );

  group('sensitive の送り分け (#1194)', () {
    // ⚠⚠ これが本丸。既定が true の利用者が外せるようになる。
    test('⚠⚠ 既定を読めていれば false を明示して送る', () async {
      await adapter.postStatus(draft(sensitive: false, explicit: true));

      expect(http.lastBody!['sensitive'], isFalse);
    });

    // ⚠ 既定を読めないサーバーでは従来どおり省く（サーバー既定に任せる）。
    test('⚠ 既定を読めていなければ false は送らない', () async {
      await adapter.postStatus(draft(sensitive: false, explicit: false));

      expect(
        http.lastBody!.containsKey('sensitive'),
        isFalse,
        reason: '⚠ 送ると、source を返さないサーバーの既定が効かなくなる',
      );
    });

    // true は旗に関わらず常に送る（従来どおり）。
    test('true は常に送る（旗に関わらず）', () async {
      await adapter.postStatus(draft(sensitive: true, explicit: false));
      expect(http.lastBody!['sensitive'], isTrue);

      await adapter.postStatus(draft(sensitive: true, explicit: true));
      expect(http.lastBody!['sensitive'], isTrue);
    });
  });
}

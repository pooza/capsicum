import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../model/account.dart';
import '../util/user_acct.dart';
import 'account_manager_provider.dart';

/// isCat の判定結果はユーザー（ActivityPub actor）に紐づくほぼ静的な
/// 事実で、閲覧中のアカウントや Riverpod の再構築によって変わらない。
/// キャッシュをモジュールスコープに置き、currentAccountProvider の変化で
/// Enricher が再生成されても結果を使い回す。
///
/// 容量は [_maxCacheSize] で丸める（FIFO eviction）。プロセス寿命で無制限
/// に肥大化させず、かつ Misskey 側で isCat を後からトグルしたユーザーの
/// 鮮度管理にも効く。
final Map<String, bool> _globalIsCatCache = {};
const int _maxCacheSize = 2000;

/// 解決に失敗した acct のネガティブキャッシュ (#1080)。値は失敗時刻。
///
/// ⚠ **これが無いと「一度遅い acct は、ずっと遅い」。**モロヘイヤの
/// `/account/is_cat` はキャッシュに無い acct をその場でリモートへ取りに行き、
/// **失敗はサーバー側にもキャッシュされない**（mulukhiya#4677）。到達不能に
/// なったサーバーのアカウントは復旧しないまま何か月も通知欄に残るので、
/// クライアント側で覚えておかないと**その通知が流れるまで毎回タイムアウトを
/// 払い続ける**ことになる。
final Map<String, DateTime> _globalIsCatFailureCache = {};

/// ネガティブキャッシュの寿命 (#1080)。
///
/// 猫耳が付くのが少し遅れるだけなので長めでよいが、**サーバーの復旧や
/// `isCat` のトグルを永久に拾えなくなるのは避けたい**ので有限にする。
const Duration _failureTtl = Duration(minutes: 30);

/// 装飾のために通知・タイムラインの表示を止めない上限 (#1080)。
///
/// ⚠ **`is_cat` 側のタイムアウト（5 秒）とは別物。**あちらは「1 リクエストを
/// いつ諦めるか」、こちらは「**呼び出し元がいつまで待つか**」。超えたら
/// エンリッチ前の値で先に描画し、解決自体はバックグラウンドで続行させる
/// （結果はキャッシュに載るので次の取得で効く）。
///
/// ⚠⚠ **適用は [IsCatEnricher] の中 1 箇所 (#1083-C)。**以前は呼び出し側
/// 4 箇所がそれぞれ `.timeout(kIsCatEnrichBudget, …)` を書いており、**超過が
/// どこでも計装されていなかった**。中へ寄せたことで、超過の観測も 1 箇所で済む。
const kIsCatEnrichBudget = Duration(seconds: 2);

/// リクエスト**全体**の連続失敗回数（モロヘイヤ単位）(#1083-C)。
final Map<String, int> _globalIsCatOutageStreak = {};

/// 直近に outage を報告した時刻（モロヘイヤ単位）(#1083-C)。
final Map<String, DateTime> _globalIsCatOutageReportedAt = {};

/// これだけ連続で「リクエストごと失敗」したら機能が死んでいるとみなす。
///
/// ⚠ **1 回では上げない。**通信断や一過性の 504 は日常的に起きる。
const int _outageStreakThreshold = 5;

/// 同じモロヘイヤについて再報告するまでの間隔（レート制限）。
const Duration _outageReportInterval = Duration(hours: 1);

/// outage の送信先 (#1083-C)。
///
/// ⚠⚠ **テストから観測するための継ぎ目。**この計装は「壊れても誰も気づかない」
/// 種類のもの——観測を足す動機そのものが「握りつぶしのせいで Sentry に一切
/// 出なかった」なので、**判定（閾値・レート制限・個別失敗を数えないこと）が
/// 静かに壊れたら意味が無い**。差し替え可能にして、判定をテストで固定する。
///
/// ⚠ テストで差し替えたら [IsCatEnricher.resetCachesForTest] で戻る。
void Function(String host, int streak) isCatOutageReporter =
    _reportIsCatOutageToSentry;

void _reportIsCatOutageToSentry(String host, int streak) {
  try {
    // ⚠ **`params` は logentry.params として実際に送られる** (#1027-A5)。
    // scrub-guard: allow: streak は連続失敗回数の int（acct も本文も含まない）
    Sentry.captureMessage(
      'is_cat enrichment keeps failing',
      level: SentryLevel.warning,
      params: [streak],
      withScope: (scope) {
        // ⚠ host はそのまま出す。プリセットかどうかで優先度を切る運用
        // （feedback_sentry_preset_server_priority）のため。
        scope.setTag('host', host);
        scope.setTag('phase', 'is_cat_enrich');
        // ⚠ **fingerprint は 1 本。**host や回数で割ると、「機能が死んでいる」
        // 1 件が host ごとにばらけて母数が読めない。
        scope.fingerprint = ['is-cat-enrich-outage'];
      },
    );
  } catch (_) {
    // Sentry の失敗でエンリッチを止めない。
  }
}

/// isCat エンリッチのキャッシュ付きユーティリティ。
///
/// モロヘイヤの `POST /account/is_cat` を使い、リモートユーザーの
/// isCat フラグを補完する。結果はプロセス寿命の間キャッシュされる。
///
/// ## ⚠⚠ 解決とキャッシュはここが唯一の実装 (#1082)
///
/// 以前は `TimelineNotifier` が `_enrichIsCat` / `_applyIsCat` /
/// `_isCatCache` を**別に持っていた**。そのため
///
/// - **#1080 で入れたネガティブキャッシュが timeline に効かず**、到達不能な
///   サーバーの acct を毎回引きに行っていた
/// - **キャッシュが共有されず**、TL で解決済みの acct を通知側がもう一度引いた
/// - **片方だけ直す事故が起きる形**だった（#1080 がまさにそれ）
///
/// timeline を含む全経路をここへ寄せた。⚠ **「キャッシュだけで塗り直す」入口
/// （[applyCachedToPosts]）も併せて用意してある** — timeline のキャッシュ温め
/// 経路が必要としていたもの。
class IsCatEnricher {
  final MulukhiyaService? _mulukhiya;
  final String? _accessToken;
  final Map<String, bool> _cache;

  IsCatEnricher({
    required MulukhiyaService? mulukhiya,
    required String? accessToken,
    Map<String, bool>? cache,
  }) : _mulukhiya = mulukhiya,
       _accessToken = accessToken,
       _cache = cache ?? _globalIsCatCache;

  /// アカウントから IsCatEnricher を生成する。Provider からの生成と
  /// ad-hoc な生成（unified notification 等）で構成ミスを防ぐためのファクトリ。
  factory IsCatEnricher.forAccount(Account account) => IsCatEnricher(
    mulukhiya: account.mulukhiya,
    accessToken: account.userSecret.accessToken,
  );

  /// 単一ユーザーの isCat を補完する。
  Future<User> enrichUser(User user) async {
    if (user.isCat || user.host == null) return user;
    final acct = userAcct(user);

    if (_cache.containsKey(acct)) {
      return _cache[acct]! ? user.copyWithIsCat(true) : user;
    }

    await _fetchWithinBudget([acct]);
    return (_cache[acct] ?? false) ? user.copyWithIsCat(true) : user;
  }

  /// ユーザーリストの isCat を一括で補完する。
  Future<List<User>> enrichUsers(List<User> users) async {
    final accts = <String>{};
    for (final user in users) {
      if (!user.isCat && user.host != null) {
        final acct = userAcct(user);
        if (!_cache.containsKey(acct)) accts.add(acct);
      }
    }

    if (accts.isNotEmpty) await _fetchWithinBudget(accts.toList());

    return users.map((user) {
      if (user.isCat || user.host == null) return user;
      final acct = userAcct(user);
      return (_cache[acct] ?? false) ? user.copyWithIsCat(true) : user;
    }).toList();
  }

  /// 通知リストのユーザー・投稿者の isCat を一括で補完する。
  Future<List<Notification>> enrichNotifications(
    List<Notification> notifications,
  ) async {
    final accts = <String>{};
    for (final n in notifications) {
      _collectAcct(n.user, accts);
      _collectAcct(n.post?.author, accts);
      _collectAcct(n.post?.reblog?.author, accts);
    }

    if (accts.isNotEmpty) await _fetchWithinBudget(accts.toList());

    if (!_cache.values.any((v) => v)) return notifications;

    return notifications.map((n) {
      final user = _maybeCatUser(n.user);
      final post = n.post != null ? _enrichPost(n.post!) : null;
      if (identical(user, n.user) && identical(post, n.post)) return n;
      return Notification(
        id: n.id,
        type: n.type,
        createdAt: n.createdAt,
        user: user,
        post: post,
        reaction: n.reaction,
        unread: n.unread,
      );
    }).toList();
  }

  /// **問い合わせをせず**、キャッシュに載っている結果だけで塗り直す (#1082)。
  ///
  /// ⚠ timeline の「キャッシュ温め」経路が使う。先に [enrichPosts] で温めてから、
  /// **その間に差し替わった最新 state** へ結果を反映するための入口。取得を挟まない
  /// ので同期。
  List<Post> applyCachedToPosts(List<Post> posts) {
    if (!_cache.values.any((v) => v)) return posts;
    return posts.map(_enrichPost).toList();
  }

  /// 投稿リストの投稿者の isCat を一括で補完する。
  Future<List<Post>> enrichPosts(List<Post> posts) async {
    final accts = <String>{};
    for (final p in posts) {
      _collectAcct(p.author, accts);
      if (p.reblog != null) _collectAcct(p.reblog!.author, accts);
    }

    if (accts.isNotEmpty) await _fetchWithinBudget(accts.toList());

    if (!_cache.values.any((v) => v)) return posts;

    return posts.map((p) => _enrichPost(p)).toList();
  }

  void _collectAcct(User? user, Set<String> accts) {
    if (user == null || user.isCat || user.host == null) return;
    final acct = userAcct(user);
    if (!_cache.containsKey(acct)) accts.add(acct);
  }

  User? _maybeCatUser(User? user) {
    if (user == null || user.isCat || user.host == null) return user;
    final acct = userAcct(user);
    return (_cache[acct] ?? false) ? user.copyWithIsCat(true) : user;
  }

  Post _enrichPost(Post p) {
    final author = _maybeCatUser(p.author);
    final reblog = p.reblog != null ? _enrichPost(p.reblog!) : null;
    if (identical(author, p.author) && identical(reblog, p.reblog)) return p;
    return p.copyWith(author: author, reblog: reblog);
  }

  /// 呼び出し元の待ち上限を掛けて [_fetchAndCache] を回す (#1083-C)。
  ///
  /// ⚠⚠ **`timeout` は下の future を止めない。**Dart の `Future.timeout` は
  /// 元の future をキャンセルしないので、解決はバックグラウンドで続き、
  /// **結果はプロセス共有のキャッシュに載る**（次の取得で効く）。
  /// ⚠ **だから `fetchIsCat` 自体に timeout を掛けてはいけない** — timeline の
  /// 旧実装はそうしており、遅れて着いた結果を捨てていた（#1082 で解消）。
  Future<void> _fetchWithinBudget(List<String> accts) async {
    // ⚠ [_fetchAndCache] は throw しない（中で catch 済み）。ここで待つのを
    // やめても unhandled error にならない。
    final pending = _fetchAndCache(accts);
    var exceeded = false;
    await pending.timeout(
      kIsCatEnrichBudget,
      onTimeout: () {
        exceeded = true;
      },
    );
    if (exceeded) _noteRequestFailure();
  }

  Future<void> _fetchAndCache(List<String> accts) async {
    if (_mulukhiya == null || _accessToken == null) return;
    // 直近に失敗した acct は問い合わせ直さない (#1080)。
    final targets = accts.where(_shouldQuery).toList(growable: false);
    if (targets.isEmpty) return;
    try {
      final result = await _mulukhiya.fetchIsCat(
        accessToken: _accessToken,
        accts: targets,
      );
      if (result == null) {
        // ⚠ **リクエスト全体の失敗では acct を落とさない**（リリース前
        // レビューで修正）。以前はここで要求した全件を 30 分ブロックして
        // いたが、`fetchIsCat` は**クライアント側の通信断とサーバー側の
        // 504 を区別せず null を返す**。機内モードの ON/OFF 1 回で、その回の
        // バッチに載った 20〜40 acct の猫耳が 30 分消えていた。
        //
        // 落とすのは「**その acct が解決できない**」と分かったときだけ
        // （下の個別 null 判定）。リクエストごと落ちたのは相手の問題とは
        // 限らないので、次の取得でもう一度試す。⚠ **タイムアウトの払い直しは
        // `is_cat` 側の 5 秒 + 呼び出し側の 2 秒バジェットで頭打ちになる**ので、
        // #1080 が直した「1 分待たされる」には戻らない。
        _noteRequestFailure();
        return;
      }
      _noteRequestSuccess();
      // 個別に解決できなかった acct（値が null）も覚える。モロヘイヤ側は
      // 失敗をキャッシュしないので、ここで止めないと毎回引きに行かせてしまう。
      _markFailed(targets.where((a) => result[a] == null));
      for (final entry in result.entries) {
        if (entry.value != null) {
          // 後から解決できたら失敗記録を消す。⚠ **これが無いと「実は解決
          // 済み」の acct が失敗キャッシュに残り続け、eviction 枠を食う。**
          _globalIsCatFailureCache.remove(_failureKey(entry.key));
          // LinkedHashMap の挿入順を維持しつつ最新エントリを末尾へ送るため
          // remove → 再 put する。FIFO の先頭（= 最古エントリ）が evict
          // 対象になる。
          _cache.remove(entry.key);
          _cache[entry.key] = entry.value!;
        }
      }
      if (_cache.length > _maxCacheSize) {
        final evict = _cache.length - _maxCacheSize;
        final victims = _cache.keys.take(evict).toList();
        for (final k in victims) {
          _cache.remove(k);
        }
      }
    } catch (_) {
      // ⚠ **例外でも acct を落とさない**（`result == null` と同じ理由）。
      // 通信断・タイムアウトは「その acct が解決できない」ことを意味しない。
      //
      // ⚠ ただし**握りつぶしたことは数える** (#1083-C)。#1080 の調査で
      // 「握りつぶしのせいで Sentry に一切出ず、原因特定に長時間かかった」
      // のに、その盲点だけが残っていた。
      _noteRequestFailure();
    }
  }

  /// 報告・集計のキー。⚠ acct ではなく**モロヘイヤ単位**（[_failureKey] と同じ理由）。
  String get _outageKey => _mulukhiya?.baseUrl ?? '-';

  void _noteRequestSuccess() {
    _globalIsCatOutageStreak.remove(_outageKey);
    _globalIsCatOutageReportedAt.remove(_outageKey);
  }

  /// リクエスト**全体**が失敗した（`result == null` / 例外 / バジェット超過）。
  ///
  /// ⚠⚠ **個別 acct の解決失敗はここに来ない。**リモートを引けないアカウントは
  /// 日常的にあり、猫耳が付かないだけの装飾。数えると母数がそれで埋まって、
  /// 見たいもの（**機能そのものが死んでいる**）が沈む。個別失敗はネガティブ
  /// キャッシュ（[_markFailed]）の担当。
  void _noteRequestFailure() {
    final key = _outageKey;
    final streak = (_globalIsCatOutageStreak[key] ?? 0) + 1;
    _globalIsCatOutageStreak[key] = streak;
    if (streak < _outageStreakThreshold) return;

    // レート制限。⚠ **1 回の障害で毎ページ送らない** — 通知ポーリングは
    // バックグラウンドでも回るので、抑えないと 1 障害で大量に積む
    // （`conversion_skip_report` が上限も dedup も持たない形になっている
    // ことへの反省・#1035-B2）。
    final now = DateTime.now();
    final reportedAt = _globalIsCatOutageReportedAt[key];
    if (reportedAt != null &&
        now.difference(reportedAt) < _outageReportInterval) {
      return;
    }
    _globalIsCatOutageReportedAt[key] = now;

    isCatOutageReporter(Uri.tryParse(key)?.host ?? '-', streak);
  }

  /// 失敗キャッシュのキー (#1080・リリース前レビューで modulo 追加)。
  ///
  /// ⚠⚠ **モロヘイヤの baseUrl で名前空間を切る。**以前は acct だけをキーに
  /// しており、**アカウント横断で共有**されていた。アカウント B のモロヘイヤが
  /// 落ちていると、健全なアカウント A でも同じ acct の猫耳が 30 分付かなく
  /// なる（「すべての通知」は全アカウントを並列に引くので実際に起きる）。
  ///
  /// 「解決できない」のは **acct とモロヘイヤの組**に対する事実であって、
  /// acct 単独の性質ではない。
  String _failureKey(String acct) => '${_mulukhiya?.baseUrl} $acct';

  /// 直近に失敗していない acct だけ問い合わせる (#1080)。
  bool _shouldQuery(String acct) {
    final key = _failureKey(acct);
    final failedAt = _globalIsCatFailureCache[key];
    if (failedAt == null) return true;
    if (DateTime.now().difference(failedAt) < _failureTtl) return false;
    _globalIsCatFailureCache.remove(key);
    return true;
  }

  void _markFailed(Iterable<String> accts) {
    final now = DateTime.now();
    for (final acct in accts) {
      _globalIsCatFailureCache[_failureKey(acct)] = now;
    }
    // 成功側と同じく上限で丸める。挿入順（＝古い順）から落とす。
    if (_globalIsCatFailureCache.length > _maxCacheSize) {
      final evict = _globalIsCatFailureCache.length - _maxCacheSize;
      final victims = _globalIsCatFailureCache.keys.take(evict).toList();
      for (final k in victims) {
        _globalIsCatFailureCache.remove(k);
      }
    }
  }

  /// テスト用。プロセス寿命のキャッシュを空にする。
  ///
  /// ⚠ **新しいプロセス寿命の状態を足したらここにも足す。**消し忘れると
  /// テストの実行順で結果が変わる。
  static void resetCachesForTest() {
    _globalIsCatCache.clear();
    _globalIsCatFailureCache.clear();
    _globalIsCatOutageStreak.clear();
    _globalIsCatOutageReportedAt.clear();
    isCatOutageReporter = _reportIsCatOutageToSentry;
  }
}

/// アカウント単位で IsCatEnricher を提供する。
final isCatEnricherProvider = Provider<IsCatEnricher>((ref) {
  final account = ref.watch(currentAccountProvider);
  return account != null
      ? IsCatEnricher.forAccount(account)
      : IsCatEnricher(mulukhiya: null, accessToken: null);
});

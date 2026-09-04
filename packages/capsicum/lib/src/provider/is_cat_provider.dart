import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
const kIsCatEnrichBudget = Duration(seconds: 2);

/// isCat エンリッチのキャッシュ付きユーティリティ。
///
/// モロヘイヤの `POST /account/is_cat` を使い、リモートユーザーの
/// isCat フラグを補完する。結果はプロセス寿命の間キャッシュされる。
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

    await _fetchAndCache([acct]);
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

    if (accts.isNotEmpty) await _fetchAndCache(accts.toList());

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

    if (accts.isNotEmpty) await _fetchAndCache(accts.toList());

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

  /// 投稿リストの投稿者の isCat を一括で補完する。
  Future<List<Post>> enrichPosts(List<Post> posts) async {
    final accts = <String>{};
    for (final p in posts) {
      _collectAcct(p.author, accts);
      if (p.reblog != null) _collectAcct(p.reblog!.author, accts);
    }

    if (accts.isNotEmpty) await _fetchAndCache(accts.toList());

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
        return;
      }
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
    }
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
  static void resetCachesForTest() {
    _globalIsCatCache.clear();
    _globalIsCatFailureCache.clear();
  }
}

/// アカウント単位で IsCatEnricher を提供する。
final isCatEnricherProvider = Provider<IsCatEnricher>((ref) {
  final account = ref.watch(currentAccountProvider);
  return account != null
      ? IsCatEnricher.forAccount(account)
      : IsCatEnricher(mulukhiya: null, accessToken: null);
});

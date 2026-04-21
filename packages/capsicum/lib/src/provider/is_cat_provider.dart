import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  /// 単一ユーザーの isCat を補完する。
  Future<User> enrichUser(User user) async {
    if (user.isCat || user.host == null) return user;
    final acct = '${user.username}@${user.host}';

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
        final acct = '${user.username}@${user.host}';
        if (!_cache.containsKey(acct)) accts.add(acct);
      }
    }

    if (accts.isNotEmpty) await _fetchAndCache(accts.toList());

    return users.map((user) {
      if (user.isCat || user.host == null) return user;
      final acct = '${user.username}@${user.host}';
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
    final acct = '${user.username}@${user.host}';
    if (!_cache.containsKey(acct)) accts.add(acct);
  }

  User? _maybeCatUser(User? user) {
    if (user == null || user.isCat || user.host == null) return user;
    final acct = '${user.username}@${user.host}';
    return (_cache[acct] ?? false) ? user.copyWithIsCat(true) : user;
  }

  Post _enrichPost(Post p) {
    final author = _maybeCatUser(p.author);
    final reblog = p.reblog != null ? _enrichPost(p.reblog!) : null;
    if (identical(author, p.author) && identical(reblog, p.reblog)) return p;
    return Post(
      id: p.id,
      postedAt: p.postedAt,
      author: author!,
      content: p.content,
      scope: p.scope,
      attachments: p.attachments,
      favouriteCount: p.favouriteCount,
      reblogCount: p.reblogCount,
      replyCount: p.replyCount,
      quoteCount: p.quoteCount,
      favourited: p.favourited,
      reblogged: p.reblogged,
      bookmarked: p.bookmarked,
      sensitive: p.sensitive,
      reactions: p.reactions,
      myReaction: p.myReaction,
      reactionEmojis: p.reactionEmojis,
      inReplyToId: p.inReplyToId,
      reblog: reblog,
      quote: p.quote,
      quoteState: p.quoteState,
      spoilerText: p.spoilerText,
      emojis: p.emojis,
      emojiHost: p.emojiHost,
      card: p.card,
      poll: p.poll,
      filterAction: p.filterAction,
      filterTitle: p.filterTitle,
      pinned: p.pinned,
      channelId: p.channelId,
      channelName: p.channelName,
      localOnly: p.localOnly,
      quotable: p.quotable,
      language: p.language,
      url: p.url,
    );
  }

  Future<void> _fetchAndCache(List<String> accts) async {
    if (_mulukhiya == null || _accessToken == null) return;
    try {
      final result = await _mulukhiya.fetchIsCat(
        accessToken: _accessToken,
        accts: accts,
      );
      if (result == null) return;
      for (final entry in result.entries) {
        if (entry.value != null) {
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
      // 通信エラー時はキャッシュせず、次回再問い合わせ
    }
  }
}

/// アカウント単位で IsCatEnricher を提供する。
final isCatEnricherProvider = Provider<IsCatEnricher>((ref) {
  final account = ref.watch(currentAccountProvider);
  return IsCatEnricher(
    mulukhiya: account?.mulukhiya,
    accessToken: account?.userSecret.accessToken,
  );
});

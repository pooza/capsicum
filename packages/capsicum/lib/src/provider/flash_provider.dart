import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../service/sentry_op_failure.dart';
import '../util/oauth_scope_error.dart';
import 'account_manager_provider.dart';

/// Play の画面の分類 (#1351)。並びがそのままタブの順になる。
///
/// ⚠ 先頭は「いいねした」（#1360）。日課で回す Play にいいねしてもらい、
/// 手元の一覧として使う運用を軸にする。人気（featured）はいいね 0 件の Play を
/// 返さないので、人の少ないサーバーでは新しい Play ほど出てこない。
enum FlashListKind {
  liked('いいねした', 'いいねした Play はありません\n日課の Play にいいねすると、ここに並びます'),
  mine('自分の', '自分の Play はありません'),
  featured('人気', '人気の Play はありません');

  const FlashListKind(this.label, this.emptyMessage);

  final String label;
  final String emptyMessage;
}

const _pageSize = 100;

/// 1 回の表示で追うページの上限。広い語の検索でサーバーを叩き続けない。
const _maxPages = 10;

/// `untilId` で最後まで（[_maxPages] まで）読む。
Future<List<Flash>> _pagedFlashes(
  Future<List<Flash>> Function(TimelineQuery query) fetch,
) async {
  final flashes = <Flash>[];
  String? maxId;
  for (var page = 0; page < _maxPages; page++) {
    final data = await fetch(TimelineQuery(maxId: maxId, limit: _pageSize));
    flashes.addAll(data);
    if (data.length < _pageSize) break;
    maxId = data.last.id;
  }
  return flashes;
}

/// いいねした Play を最後まで読む（#1360）。
///
/// ⚠ カーソルは Flash の ID ではなく、いいねの ID（[LikedFlashEntry.likeId]）。
Future<List<Flash>> _pagedLikedFlashes(FlashSupport support) async {
  final flashes = <Flash>[];
  String? maxId;
  for (var page = 0; page < _maxPages; page++) {
    final data = await support.getLikedFlashes(
      query: TimelineQuery(maxId: maxId, limit: _pageSize),
    );
    flashes.addAll(data.map((e) => e.flash));
    if (data.length < _pageSize) break;
    maxId = data.last.likeId;
  }
  return flashes;
}

/// 取得の失敗を観測へ流してから、そのまま画面へ返す。
///
/// ⚠ 権限の足りない古いトークンの失敗は送らない（再ログインで直る既知の条件）。
Future<List<Flash>> _fetchFlashList(
  Ref ref,
  String operation,
  Future<List<Flash>> Function() fetch,
) async {
  // ⚠ 通信の前に取る。通信の間に provider が破棄されると `ref` を読めない。
  final account = ref.read(currentAccountProvider);
  try {
    return await fetch();
  } catch (e, st) {
    if (!isOAuthScopeError(e)) {
      reportOpFailure(
        tagKey: 'flash.list',
        operation: operation,
        error: e,
        stackTrace: st,
        account: account,
      );
    }
    rethrow;
  }
}

final flashListProvider = FutureProvider.autoDispose
    .family<List<Flash>, FlashListKind>((ref, kind) async {
      final adapter = ref.watch(currentAdapterProvider);
      if (adapter is! FlashSupport) return const [];
      final support = adapter as FlashSupport;
      return _fetchFlashList(
        ref,
        kind.name,
        () => switch (kind) {
          FlashListKind.liked => _pagedLikedFlashes(support),
          FlashListKind.mine => _pagedFlashes(
            (query) => support.getMyFlashes(query: query),
          ),
          FlashListKind.featured => support.getFeaturedFlashes(),
        },
      );
    }, dependencies: [currentAdapterProvider, currentAccountProvider]);

final flashSearchProvider = FutureProvider.autoDispose
    .family<List<Flash>, String>((ref, text) async {
      final adapter = ref.watch(currentAdapterProvider);
      if (adapter is! FlashSupport) return const [];
      final support = adapter as FlashSupport;
      return _fetchFlashList(
        ref,
        'search',
        () =>
            _pagedFlashes((query) => support.searchFlashes(text, query: query)),
      );
    }, dependencies: [currentAdapterProvider, currentAccountProvider]);

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../service/sentry_op_failure.dart';
import '../util/oauth_scope_error.dart';
import 'account_manager_provider.dart';

/// Play の画面の分類 (#1351)。並びがそのままタブの順になる。
///
/// ⚠ 先頭は「いつもの」（#1360）＝ 自分の Play といいねした Play を合わせたもの。
/// 日課で回す Play にいいねしてもらい、手元の一覧として使う運用を軸にする。
/// 人気（featured）はいいね 0 件の Play を返さないので、人の少ないサーバーでは
/// 新しい Play ほど出てこない。⚠ Misskey は自分の Play へのいいねを断る
/// （`YOUR_FLASH`）ので、いいねだけでは自作の Play が並ばない。自分の Play を
/// 混ぜるのはそのため。
enum FlashListKind {
  usual('いつもの', 'いつもの Play はありません\n日課の Play にいいねするか自分で作ると、ここに並びます'),
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

/// 「いつもの」（#1360）。自分の Play を先に、続けていいねした Play を並べる。
///
/// ⚠ 同じ Play は 1 回だけ出す（自分の Play にはいいねできないので通常は重ならない
/// が、作者が変わる経路をここで仮定しない）。
Future<List<Flash>> _usualFlashes(FlashSupport support) async {
  final (mine, liked) = await (
    _pagedFlashes((query) => support.getMyFlashes(query: query)),
    _pagedLikedFlashes(support),
  ).wait;
  final seen = <String>{};
  return [
    for (final flash in [...mine, ...liked])
      if (seen.add(flash.id)) flash,
  ];
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
          FlashListKind.usual => _usualFlashes(support),
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

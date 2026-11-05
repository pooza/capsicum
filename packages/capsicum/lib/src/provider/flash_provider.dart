import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/oauth_scope_error.dart';
import 'account_manager_provider.dart';
import 'list_fetch.dart';

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

/// 「いつもの」（#1360）。自分の Play を先に、続けていいねした Play を並べる。
///
/// ⚠ ページ送りはアダプターが持つ（#1361・チャンネルと同じ層）。
///
/// ⚠ 同じ Play は 1 回だけ出す（自分の Play にはいいねできないので通常は重ならない
/// が、作者が変わる経路をここで仮定しない）。
///
/// ⚠ レコードの `.wait` を使わない。失敗を `ParallelWaitError` に包むので、
/// 古いトークンの 403 が [isOAuthScopeError] をすり抜け、再ログインの案内が
/// 消えて Sentry へ流れる。`Future.wait` は最初の失敗をそのまま投げ直す。
Future<List<Flash>> _usualFlashes(FlashSupport support) async {
  final [mine, liked] = await Future.wait([
    support.getMyFlashes(),
    support.getLikedFlashes(),
  ]);
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
) => fetchListReportingFailure(
  ref,
  tagKey: 'flash.list',
  operation: operation,
  fetch: fetch,
);

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
          FlashListKind.mine => support.getMyFlashes(),
          FlashListKind.featured => support.getFeaturedFlashes(),
        },
      );
    }, dependencies: [currentAdapterProvider, currentAccountProvider]);

final flashSearchProvider = FutureProvider.autoDispose
    .family<List<Flash>, String>((ref, text) async {
      final adapter = ref.watch(currentAdapterProvider);
      if (adapter is! FlashSupport) return const [];
      final support = adapter as FlashSupport;
      return _fetchFlashList(ref, 'search', () => support.searchFlashes(text));
    }, dependencies: [currentAdapterProvider, currentAccountProvider]);

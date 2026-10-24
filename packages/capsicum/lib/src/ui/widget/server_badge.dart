import 'package:flutter/material.dart';

import '../../provider/server_config_provider.dart';
import '../../service/server_metadata_cache.dart';

/// 画面に出すサーバーの名前（サーバーが名乗る名前。まだ取れていなければホスト名）。
///
/// ⚠ 上部のバーのバッジ（[ServerBadge]）と簡易投稿バーのヒント (#1313) で
/// 同じものを出すため、出どころをここ 1 つにする。
String serverDisplayName(String host) =>
    ServerMetadataCache.instance.getCached(host)?.name ?? host;

/// 入力欄のヒント。**どのサーバーへ投稿するか**を出す（「美食丼で投稿...」）。
/// 簡易投稿バー (#1313) と投稿画面 (#1328) が同じものを使う。
///
/// ⚠ 同じアバター・同じ表示名を複数のサーバーで使っていると、アイコンや
/// 表示名では見分けられない。投稿画面は「今なにしてる？」だけで何も出しておらず、
/// 投稿するアカウントを相当な頻度で取り違えていた（2026-10-21 pooza）。
///
/// ⚠ サーバー名を先に置く。デスクトップの狭幅運用ではヒントの後ろが切れる。
/// 打ち始めると消えるが、気付きたいのは打つ前なので足りる（2026-10-19 pooza）。
///
/// ⚠ [host] には**実際に投稿するアカウント**を渡す。デッキでは開いたカラムの
/// アカウントになる（`currentAccountProvider` がカラムのスコープを返す）。
String postTargetHint({required String postLabel, required String? host}) =>
    host == null ? '$postLabel...' : '${serverDisplayName(host)}で$postLabel...';

/// サーバーのアイコン（favicon）(#1331)。
///
/// ⚠ **投稿するアカウントの取り違え**への手当て。favicon が出ている場所では
/// まず間違えない（2026-10-21 pooza）。⚠ ダイスキーとデルムリン丼は favicon が
/// 同じなので、**これだけでは見分けられない**。サーバー名（[ServerBadge] /
/// [postTargetHint]）と併せて出す。
///
/// 出どころは [ServerMetadataCache] の `iconUrl`（サーバー名と同じ問い合わせ）。
///
/// ⚠⚠ **キャッシュを読むだけで、自分では取りに行かない**（[ServerBadge] の
/// サーバー名と同じ）。出す場所はどれも自分のアカウントのサーバーで、ログイン・
/// 起動の時点でアカウント管理側が**種別のヒント付きで**取ってある
/// （`preferMisskey`・#827）。ここでヒント無しに取ると、Misskey 系のフォークで
/// 名前・アイコンが Mastodon 互換の見かけに化けたものがキャッシュに入りうる。
///
/// ⚠ 取れていない・読めない（SVG など）ときは**何も出さない**（[size] の幅も
/// 取らない）。代わりの絵を出すと「どのサーバーでもない印」になり、見分ける
/// 手がかりにならない。
class ServerFavicon extends StatelessWidget {
  final String host;
  final double size;

  const ServerFavicon({super.key, required this.host, this.size = 16});

  @override
  Widget build(BuildContext context) {
    final url = ServerMetadataCache.instance.getCached(host)?.iconUrl;
    if (url == null || url.isEmpty) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 5),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
  }
}

/// テーマカラー背景のサーバー名バッジ。
/// インスタンスティッカーと同じスタイル。
class ServerBadge extends StatelessWidget {
  final String host;
  final Color color;

  /// バッジの左に [ServerFavicon] を出すか (#1331)。
  ///
  /// ⚠ **既定は出さない。**投稿ごとのインスタンスティッカーも同じバッジを
  /// 使っており、そこに出すと全投稿に favicon が並ぶ。出すのは「自分がどの
  /// アカウントか」を示す場所（上部のバー・ドロワー・投稿画面）だけ。
  final bool showIcon;

  const ServerBadge({
    super.key,
    required this.host,
    required this.color,
    this.showIcon = false,
  });

  /// ホストからテーマカラーとサーバー名を解決してバッジを構築する。
  factory ServerBadge.fromHost(
    String host, {
    Key? key,
    required Map<String, Color> themeColors,
    bool showIcon = false,
  }) {
    return ServerBadge(
      key: key,
      host: host,
      color: resolveHostColor(themeColors, host),
      showIcon: showIcon,
    );
  }

  @override
  Widget build(BuildContext context) {
    final badge = _buildBadge(context);
    if (!showIcon) return badge;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ServerFavicon(host: host),
        const SizedBox(width: 4),
        Flexible(child: badge),
      ],
    );
  }

  Widget _buildBadge(BuildContext context) {
    final label = serverDisplayName(host);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          fontSize: 11,
          // ⚠ 白に固定しない（#1240・明るい色のサーバーで読めなくなる）。
          color: foregroundOnHostColor(color),
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

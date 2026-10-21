import 'package:flutter/material.dart';

import '../../provider/server_config_provider.dart';
import '../../service/server_metadata_cache.dart';

/// 画面に出すサーバーの名前（サーバーが名乗る名前。まだ取れていなければホスト名）。
///
/// ⚠ 上部のバーのバッジ（[ServerBadge]）と簡易投稿バーのヒント (#1313) で
/// 同じものを出すため、出どころをここ 1 つにする。
String serverDisplayName(String host) =>
    ServerMetadataCache.instance.getCached(host)?.name ?? host;

/// 入力欄のヒント。**どのサーバーへ投稿するか**を出す（「美食丼に投稿...」）。
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
    host == null ? '$postLabel...' : '${serverDisplayName(host)}に$postLabel...';

/// テーマカラー背景のサーバー名バッジ。
/// インスタンスティッカーと同じスタイル。
class ServerBadge extends StatelessWidget {
  final String host;
  final Color color;

  const ServerBadge({super.key, required this.host, required this.color});

  /// ホストからテーマカラーとサーバー名を解決してバッジを構築する。
  factory ServerBadge.fromHost(
    String host, {
    Key? key,
    required Map<String, Color> themeColors,
  }) {
    return ServerBadge(
      key: key,
      host: host,
      color: resolveHostColor(themeColors, host),
    );
  }

  @override
  Widget build(BuildContext context) {
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

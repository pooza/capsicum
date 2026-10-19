import 'package:flutter/material.dart';

import '../../provider/server_config_provider.dart';
import '../../service/server_metadata_cache.dart';

/// 画面に出すサーバーの名前（サーバーが名乗る名前。まだ取れていなければホスト名）。
///
/// ⚠ 上部のバーのバッジ（[ServerBadge]）と簡易投稿バーのヒント (#1313) で
/// 同じものを出すため、出どころをここ 1 つにする。
String serverDisplayName(String host) =>
    ServerMetadataCache.instance.getCached(host)?.name ?? host;

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

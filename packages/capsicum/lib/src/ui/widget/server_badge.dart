import 'package:flutter/material.dart';

import '../../provider/server_config_provider.dart';
import '../../service/server_metadata_cache.dart';

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
    final cached = ServerMetadataCache.instance.getCached(host);
    final label = cached?.name ?? host;

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
          color: Colors.white,
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

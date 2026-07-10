import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../constants.dart';

class ServerMetadata {
  final String name;
  final String? iconUrl;
  final String? themeColor;

  /// サーバーソフトウェアのバージョン（Mastodon `/api/v(1|2)/instance` の
  /// `version` / Misskey `/api/meta` の `version`）。NodeInfo `software.version`
  /// と同値で、ドロワーのバージョン表示 (#774) を TTL で鮮度更新するために保持する。
  final String? softwareVersion;

  const ServerMetadata({
    required this.name,
    this.iconUrl,
    this.themeColor,
    this.softwareVersion,
  });
}

class _CacheEntry {
  final ServerMetadata? metadata;
  final DateTime fetchedAt;

  _CacheEntry(this.metadata, this.fetchedAt);

  bool get isExpired {
    // 成功時は1時間、失敗（null）時は5分で期限切れ
    final ttl = metadata != null
        ? const Duration(hours: 1)
        : const Duration(minutes: 5);
    return DateTime.now().difference(fetchedAt) > ttl;
  }
}

class ServerMetadataCache {
  ServerMetadataCache._();
  static final instance = ServerMetadataCache._();

  final _cache = <String, _CacheEntry>{};
  final _pending = <String, Future<ServerMetadata?>>{};

  ServerMetadata? getCached(String host) {
    final entry = _cache[host];
    if (entry == null || entry.isExpired) return null;
    return entry.metadata;
  }

  /// [forceRefresh] が true のときは TTL 内でも再取得する。「サーバー情報」画面を
  /// 開いた直後にドロワー表示を確実に最新化する用途 (#774 method 2)。進行中の
  /// fetch があればそれに相乗りする（多重リクエストは避ける）。
  Future<ServerMetadata?> fetch(String host, {bool forceRefresh = false}) {
    final entry = _cache[host];
    if (!forceRefresh && entry != null && !entry.isExpired) {
      return Future.value(entry.metadata);
    }
    return _pending.putIfAbsent(host, () => _doFetch(host));
  }

  Future<ServerMetadata?> _doFetch(String host) async {
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: kNetworkConnectTimeout,
          receiveTimeout: kNetworkReceiveTimeout,
        ),
      );
      final metadata =
          await _tryMastodon(dio, host) ??
          await _tryMisskey(dio, host) ??
          await _tryPieFed(dio, host);
      _cache[host] = _CacheEntry(metadata, DateTime.now());
      _pending.remove(host);
      return metadata;
    } catch (e) {
      debugPrint('capsicum: failed to fetch server metadata for $host: $e');
      _cache[host] = _CacheEntry(null, DateTime.now());
      _pending.remove(host);
      return null;
    }
  }

  Future<ServerMetadata?> _tryMastodon(Dio dio, String host) async {
    try {
      final res = await dio.get('https://$host/api/v2/instance');
      if (res.statusCode == 200) {
        final data = res.data as Map<String, dynamic>;
        return ServerMetadata(
          name: data['title'] as String? ?? host,
          iconUrl: _extractIcon(data, host),
          themeColor: _extractColor(data),
          softwareVersion: data['version'] as String?,
        );
      }
    } on DioException {
      // Fall through to try v1.
    }
    try {
      final res = await dio.get('https://$host/api/v1/instance');
      if (res.statusCode == 200) {
        final data = res.data as Map<String, dynamic>;
        return ServerMetadata(
          name: data['title'] as String? ?? host,
          iconUrl: 'https://$host/favicon.ico',
          themeColor: null,
          softwareVersion: data['version'] as String?,
        );
      }
    } on DioException {
      // Not Mastodon.
    }
    return null;
  }

  Future<ServerMetadata?> _tryMisskey(Dio dio, String host) async {
    try {
      final res = await dio.post('https://$host/api/meta', data: {});
      if (res.statusCode == 200) {
        final data = res.data as Map<String, dynamic>;
        return ServerMetadata(
          name: data['name'] as String? ?? host,
          iconUrl: data['iconUrl'] as String?,
          themeColor: data['themeColor'] as String?,
          softwareVersion: data['version'] as String?,
        );
      }
    } on DioException {
      // Not Misskey.
    }
    return null;
  }

  /// PieFed (Lemmy 系) のサイト情報。Mastodon / Misskey 判定が空振りしたときの
  /// フォールバック (#807)。プリセット圏ではグループアカウントの多くが PieFed
  /// サーバー由来で、capsicum の公式コミュニティ自体も PieFed のもの。REST API は
  /// 実験的（エンドポイントが `/api/alpha` 下）なので変化に備え失敗は握り潰す。
  Future<ServerMetadata?> _tryPieFed(Dio dio, String host) async {
    try {
      final res = await dio.get('https://$host/api/alpha/site');
      if (res.statusCode == 200) {
        final data = res.data as Map<String, dynamic>;
        final site = data['site'] as Map<String, dynamic>?;
        if (site == null) return null;
        return ServerMetadata(
          name: site['name'] as String? ?? host,
          iconUrl: site['icon'] as String?,
          themeColor: null,
          softwareVersion: data['version'] as String?,
        );
      }
    } on DioException {
      // Not PieFed.
    }
    return null;
  }

  String _extractIcon(Map<String, dynamic> v2Data, String host) {
    // Mastodon 4.3+: icon is an array of {src, sizes}
    final icon = v2Data['icon'];
    if (icon is List && icon.isNotEmpty) {
      final first = icon.first;
      if (first is Map<String, dynamic>) {
        final src = first['src'] as String?;
        if (src != null) return src;
      }
    }
    // Older Mastodon: icon is a map with url
    if (icon is Map<String, dynamic>) {
      final url = icon['url'] as String?;
      if (url != null) return url;
    }
    return 'https://$host/favicon.ico';
  }

  String? _extractColor(Map<String, dynamic> v2Data) {
    // Mastodon 4.3+ includes accent_color in configuration.
    final config = v2Data['configuration'] as Map<String, dynamic>?;
    final accentColor = config?['accent_color'] as String?;
    if (accentColor != null) return accentColor;
    return null;
  }

  @visibleForTesting
  void clear() {
    _cache.clear();
    _pending.clear();
  }
}

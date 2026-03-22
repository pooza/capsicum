import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

class ServerMetadata {
  final String name;
  final String? iconUrl;
  final String? themeColor;

  const ServerMetadata({
    required this.name,
    this.iconUrl,
    this.themeColor,
  });
}

class ServerMetadataCache {
  ServerMetadataCache._();
  static final instance = ServerMetadataCache._();

  final _cache = <String, ServerMetadata>{};
  final _pending = <String, Future<ServerMetadata?>>{};

  ServerMetadata? getCached(String host) => _cache[host];

  Future<ServerMetadata?> fetch(String host) {
    if (_cache.containsKey(host)) {
      return Future.value(_cache[host]);
    }
    return _pending.putIfAbsent(host, () => _doFetch(host));
  }

  Future<ServerMetadata?> _doFetch(String host) async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ));
      final metadata = await _tryMastodon(dio, host) ??
          await _tryMisskey(dio, host);
      if (metadata != null) {
        _cache[host] = metadata;
      }
      _pending.remove(host);
      return metadata;
    } catch (e) {
      debugPrint('capsicum: failed to fetch server metadata for $host: $e');
      _pending.remove(host);
      return null;
    }
  }

  Future<ServerMetadata?> _tryMastodon(Dio dio, String host) async {
    try {
      final res = await dio.get('https://$host/api/v2/instance');
      if (res.statusCode == 200) {
        final data = res.data as Map<String, dynamic>;
        final thumbnail = data['thumbnail'] as Map<String, dynamic>?;
        return ServerMetadata(
          name: data['title'] as String? ?? host,
          iconUrl: thumbnail?['url'] as String?,
          themeColor: _extractColor(data),
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
          iconUrl: data['thumbnail'] as String?,
          themeColor: null,
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
        );
      }
    } on DioException {
      // Not Misskey.
    }
    return null;
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

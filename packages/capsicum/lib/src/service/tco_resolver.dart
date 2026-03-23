import 'package:dio/dio.dart';

/// Resolves t.co short URLs to their actual destination URLs.
///
/// Results are cached in memory to avoid repeated HTTP requests.
class TcoResolver {
  TcoResolver._();

  static final _cache = <String, String>{};
  static final _pending = <String, Future<String?>>{};
  static final _dio = Dio(
    BaseOptions(
      followRedirects: false,
      validateStatus: (status) => status != null && status < 400,
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
    ),
  );

  /// Returns `true` if the URL is a t.co short link.
  static bool isTcoUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && uri.host == 't.co';
  }

  /// Returns the cached resolved URL, or `null` if not yet resolved.
  static String? getCached(String url) => _cache[url];

  /// Resolves a t.co URL by following the HTTP redirect.
  /// Returns the destination URL, or `null` on failure.
  static Future<String?> resolve(String url) {
    if (_cache.containsKey(url)) return Future.value(_cache[url]);
    return _pending.putIfAbsent(url, () => _resolve(url));
  }

  static Future<String?> _resolve(String url) async {
    try {
      final response = await _dio.head(url);
      final location = response.headers.value('location');
      if (location != null && location != url) {
        _cache[url] = location;
        return location;
      }
    } catch (_) {}
    _pending.remove(url);
    return null;
  }
}

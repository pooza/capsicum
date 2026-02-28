import 'package:dio/dio.dart';

class MulukhiyaAbout {
  final String version;
  final String controllerType;
  final String? packageUrl;

  const MulukhiyaAbout({
    required this.version,
    required this.controllerType,
    this.packageUrl,
  });
}

class MulukhiyaService {
  final Dio _dio;
  final String baseUrl;
  final String controllerType;
  final String version;

  MulukhiyaService._({
    required Dio dio,
    required this.baseUrl,
    required this.controllerType,
    required this.version,
  }) : _dio = dio;

  /// Detect mulukhiya by requesting GET /mulukhiya/api/about.
  /// Returns [MulukhiyaService] if present, null otherwise.
  static Future<MulukhiyaService?> detect(Dio dio, String domain) async {
    try {
      final response = await dio.get('https://$domain/mulukhiya/api/about');
      if (response.statusCode == 200 && response.data is Map) {
        final data = response.data as Map<String, dynamic>;
        final package = data['package'] as Map<String, dynamic>?;
        final config = data['config'] as Map<String, dynamic>?;
        if (package == null || config == null) return null;

        return MulukhiyaService._(
          dio: dio,
          baseUrl: 'https://$domain/mulukhiya/api',
          controllerType: config['controller'] as String? ?? 'mastodon',
          version: package['version'] as String? ?? '0.0.0',
        );
      }
    } on DioException {
      // Not found or connection error — mulukhiya not present
    }
    return null;
  }

  Future<MulukhiyaAbout> getAbout() async {
    final response = await _dio.get('$baseUrl/about');
    final data = response.data as Map<String, dynamic>;
    final package = data['package'] as Map<String, dynamic>;
    return MulukhiyaAbout(
      version: package['version'] as String,
      controllerType: (data['config']
          as Map<String, dynamic>)['controller'] as String,
      packageUrl: package['url'] as String?,
    );
  }
}

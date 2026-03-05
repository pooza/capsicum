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

class MulukhiyaProgram {
  final String name;
  final String? series;
  final String? episode;
  final String? episodeSuffix;
  final String? subtitle;
  final bool air;
  final bool livecure;
  final int? minutes;
  final List<String> extraTags;

  const MulukhiyaProgram({
    required this.name,
    this.series,
    this.episode,
    this.episodeSuffix,
    this.subtitle,
    this.air = false,
    this.livecure = false,
    this.minutes,
    this.extraTags = const [],
  });
}

class MulukhiyaService {
  final Dio _dio;
  final String baseUrl;
  final String controllerType;
  final String version;
  String? _token;

  MulukhiyaService._({
    required Dio dio,
    required this.baseUrl,
    required this.controllerType,
    required this.version,
  }) : _dio = dio;

  /// Set the authentication token for API calls that require it.
  void setToken(String token) {
    _token = token;
  }

  Map<String, String> get _authHeaders =>
      _token != null ? {'Authorization': 'Bearer $_token'} : {};

  /// Detect mulukhiya by requesting GET /mulukhiya/api/about.
  /// Returns [MulukhiyaService] if present, null otherwise.
  static Future<MulukhiyaService?> detect(Dio dio, String domain) async {
    try {
      final response = await dio.get(
        'https://$domain/mulukhiya/api/about',
        options: Options(
          responseType: ResponseType.json,
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
        ),
      );
      if (response.statusCode != 200) return null;
      final data = response.data is Map<String, dynamic>
          ? response.data as Map<String, dynamic>
          : null;
      if (data == null) return null;

      final package = data['package'] as Map<String, dynamic>?;
      final config = data['config'] as Map<String, dynamic>?;
      if (package == null || config == null) return null;

      return MulukhiyaService._(
        dio: dio,
        baseUrl: 'https://$domain/mulukhiya/api',
        controllerType: config['controller'] as String? ?? 'mastodon',
        version: package['version'] as String? ?? '0.0.0',
      );
    } catch (_) {
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

  /// Fetch the program list for tagset selection.
  Future<Map<String, MulukhiyaProgram>> getProgram() async {
    final response = await _dio.get('$baseUrl/program');
    final data = response.data as Map<String, dynamic>;
    final programs = <String, MulukhiyaProgram>{};
    for (final entry in data.entries) {
      final v = entry.value;
      if (v is! Map<String, dynamic>) continue;
      if (v['enable'] != true) continue;
      programs[entry.key] = MulukhiyaProgram(
        name: entry.key,
        series: v['series'] as String?,
        episode: v['episode']?.toString(),
        episodeSuffix: v['episode_suffix'] as String? ?? '話',
        subtitle: v['subtitle'] as String?,
        air: v['air'] == true,
        livecure: v['livecure'] == true,
        minutes: v['minutes'] as int?,
        extraTags: (v['extra_tags'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            [],
      );
    }
    return programs;
  }

  /// Trigger program data update on the server.
  Future<void> updateProgram() async {
    await _dio.post('$baseUrl/program/update');
  }

  /// Change tags on a status and re-post it.
  Future<void> statusTags({
    required String id,
    required List<String> tags,
  }) async {
    await _dio.post(
      '$baseUrl/status/tags',
      data: {'id': id, 'tags': tags},
      options: Options(headers: _authHeaders),
    );
  }
}

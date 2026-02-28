import 'dart:convert';

import 'package:dio/dio.dart';

import 'backend_type.dart';

class InstanceProbe {
  final BackendType type;

  const InstanceProbe({required this.type});
}

Map<String, dynamic> _ensureMap(dynamic data) {
  if (data is Map<String, dynamic>) return data;
  if (data is String) return jsonDecode(data) as Map<String, dynamic>;
  throw FormatException('Unexpected response type: ${data.runtimeType}');
}

/// Probe a server to detect its backend type via NodeInfo.
Future<InstanceProbe?> probeInstance(Dio dio, String host) async {
  try {
    final nodeInfoResponse = await dio.get(
      'https://$host/.well-known/nodeinfo',
    );
    if (nodeInfoResponse.statusCode != 200) return null;

    final nodeInfoData = _ensureMap(nodeInfoResponse.data);
    final links = nodeInfoData['links'] as List?;
    if (links == null || links.isEmpty) return null;

    // Find a nodeinfo 2.x link
    Map<String, dynamic>? link;
    for (final l in links) {
      final rel = l['rel'] as String?;
      if (rel != null && rel.contains('/ns/schema/2.')) {
        link = l as Map<String, dynamic>;
        break;
      }
    }
    if (link == null) return null;

    final href = link['href'] as String;
    final infoResponse = await dio.get(href);
    if (infoResponse.statusCode != 200) return null;

    final infoData = _ensureMap(infoResponse.data);
    final software = infoData['software'] as Map<String, dynamic>?;
    if (software == null) return null;

    final name = (software['name'] as String?)?.toLowerCase();
    return switch (name) {
      'mastodon' => const InstanceProbe(type: BackendType.mastodon),
      'misskey' => const InstanceProbe(type: BackendType.misskey),
      _ => null,
    };
  } on DioException catch (e) {
    throw Exception('サーバーに接続できません: ${e.message}');
  }
}

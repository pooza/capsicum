import 'package:dio/dio.dart';

import 'backend_type.dart';

class InstanceProbe {
  final BackendType type;

  const InstanceProbe({required this.type});
}

/// Probe a server to detect its backend type via NodeInfo.
Future<InstanceProbe?> probeInstance(Dio dio, String host) async {
  try {
    final nodeInfoResponse = await dio.get(
      'https://$host/.well-known/nodeinfo',
    );
    if (nodeInfoResponse.statusCode != 200) return null;

    final links = nodeInfoResponse.data['links'] as List?;
    if (links == null || links.isEmpty) return null;

    // Prefer nodeinfo 2.1 or 2.0
    final link = links.firstWhere(
      (l) => (l['rel'] as String).contains('nodeinfo/2.'),
      orElse: () => null,
    );
    if (link == null) return null;

    final href = link['href'] as String;
    final infoResponse = await dio.get(href);
    if (infoResponse.statusCode != 200) return null;

    final software = infoResponse.data['software'] as Map<String, dynamic>?;
    if (software == null) return null;

    final name = (software['name'] as String?)?.toLowerCase();
    return switch (name) {
      'mastodon' => const InstanceProbe(type: BackendType.mastodon),
      'misskey' => const InstanceProbe(type: BackendType.misskey),
      _ => null,
    };
  } on DioException {
    return null;
  }
}

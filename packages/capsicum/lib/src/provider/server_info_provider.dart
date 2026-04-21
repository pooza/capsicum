import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import 'account_manager_provider.dart';

class HealthCheckResult {
  final String name;
  final bool ok;
  final String? detail;
  final Duration? responseTime;

  const HealthCheckResult({
    required this.name,
    required this.ok,
    this.detail,
    this.responseTime,
  });
}

class ServerInfoState {
  final Instance? instance;
  final List<HealthCheckResult> healthChecks;
  final bool isCheckingHealth;

  const ServerInfoState({
    this.instance,
    this.healthChecks = const [],
    this.isCheckingHealth = false,
  });

  ServerInfoState copyWith({
    Instance? instance,
    List<HealthCheckResult>? healthChecks,
    bool? isCheckingHealth,
  }) => ServerInfoState(
    instance: instance ?? this.instance,
    healthChecks: healthChecks ?? this.healthChecks,
    isCheckingHealth: isCheckingHealth ?? this.isCheckingHealth,
  );
}

class ServerInfoNotifier extends AutoDisposeAsyncNotifier<ServerInfoState> {
  @override
  Future<ServerInfoState> build() async {
    final adapter = ref.watch(currentAdapterProvider);
    if (adapter == null) return const ServerInfoState();

    final instance = await adapter.getInstance();

    // Detect software name via NodeInfo.
    String? softwareName;
    try {
      final probe = await probeInstance(
        Dio(BaseOptions(connectTimeout: kNetworkConnectTimeout)),
        adapter.host,
      );
      if (probe != null) {
        softwareName = probe.type == BackendType.mastodon
            ? 'Mastodon'
            : 'Misskey';
      }
    } catch (_) {}

    final enriched = Instance(
      name: instance.name,
      softwareName: softwareName,
      description: instance.description,
      iconUrl: instance.iconUrl,
      version: instance.version,
      themeColor: instance.themeColor,
      userCount: instance.userCount,
      postCount: instance.postCount,
      contactEmail: instance.contactEmail,
      contactAccount: instance.contactAccount,
      contactUrl: instance.contactUrl,
      rules: instance.rules,
      privacyPolicyUrl: instance.privacyPolicyUrl,
      statusUrl: instance.statusUrl,
    );
    return ServerInfoState(instance: enriched);
  }

  Future<void> runHealthChecks() async {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(
      current.copyWith(isCheckingHealth: true, healthChecks: []),
    );

    final adapter = ref.read(currentAdapterProvider);
    if (adapter == null) return;

    final results = <HealthCheckResult>[];

    if (adapter is MastodonAdapter) {
      results.add(await _check('Mastodon', () => adapter.client.checkHealth()));
      results.add(
        await _check('Streaming', () => adapter.client.checkStreamingHealth()),
      );
    } else if (adapter is MisskeyAdapter) {
      results.add(
        await _check('Misskey Ping', () async {
          final r = await adapter.client.ping();
          return r.toString();
        }),
      );
    }

    // NodeInfo
    results.add(
      await _check('NodeInfo', () async {
        final dio = Dio(
          BaseOptions(
            baseUrl: 'https://${adapter.host}',
            connectTimeout: kNetworkConnectTimeout,
            receiveTimeout: kNetworkReceiveTimeout,
          ),
        );
        final response = await dio.get('/.well-known/nodeinfo');
        final data = response.data as Map<String, dynamic>;
        final links = data['links'] as List<dynamic>;
        return '${links.length} link(s)';
      }),
    );

    // Mulukhiya
    final mulukhiya = ref.read(currentMulukhiyaProvider);
    if (mulukhiya != null) {
      results.add(
        await _check('モロヘイヤ', () async {
          final data = await mulukhiya.checkHealth();
          return data.toString();
        }),
      );
    }

    state = AsyncData(
      current.copyWith(healthChecks: results, isCheckingHealth: false),
    );
  }

  Future<HealthCheckResult> _check(
    String name,
    Future<String> Function() fn,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final detail = await fn();
      sw.stop();
      return HealthCheckResult(
        name: name,
        ok: true,
        detail: detail,
        responseTime: sw.elapsed,
      );
    } catch (e) {
      sw.stop();
      return HealthCheckResult(
        name: name,
        ok: false,
        detail: e.toString(),
        responseTime: sw.elapsed,
      );
    }
  }
}

final serverInfoProvider =
    AsyncNotifierProvider.autoDispose<ServerInfoNotifier, ServerInfoState>(
      ServerInfoNotifier.new,
    );

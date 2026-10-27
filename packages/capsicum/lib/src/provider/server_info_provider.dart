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

  /// このサーバーには、この確認の口が無い (#1337)。⚠ [ok] は false だが、
  /// 画面はエラーとして出さない。
  final bool unavailable;

  const HealthCheckResult({
    required this.name,
    required this.ok,
    this.detail,
    this.responseTime,
    this.unavailable = false,
  });
}

/// ヘルスチェックの口が無いことを表す (#1337)。
class HealthEndpointMissing implements Exception {
  const HealthEndpointMissing();
}

/// [error] が「確認の口が無い」を指しているか (#1337)。
///
/// ⚠ Mastodon の一種として動いているフォーク（Akkoma など）には
/// `/api/v1/streaming/health` が無く 404 を返す。ストリーミング自体は動いて
/// いるので、エラーとして出すと誤解させる。
bool isHealthEndpointMissing(Object error) =>
    error is HealthEndpointMissing ||
    (error is DioException && error.response?.statusCode == 404);

/// ヘルスチェックの応答が HTML か (#1337)。⚠ Akkoma の `/health` は、口が
/// 無いぶんを SPA の受け皿が 200 の HTML で返す（本家は `OK` の平文）。
bool looksLikeHtml(String body) {
  final head = body.trimLeft().toLowerCase();
  return head.startsWith('<!doctype html') || head.startsWith('<html');
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

    // モロヘイヤ導入鯖では設立日(正式オープン)・プレ公開日を `/about` から採用
    // する (#818)。モロヘイヤの founded_at は手設定 or 最古アカウント近似を
    // サーバー側で吸収済みなので、client のヒューリスティック [Instance.foundedAt]
    // より優先する。founded_at が null (DB 未接続等) の時は copyWith の `?? this`
    // で client 側ヒューリスティックにフォールバックする。preopened_at は手設定
    // 時のみ非 null。
    final mulukhiya = ref.watch(currentMulukhiyaProvider);

    // NodeInfo 由来のソフト名だけ後付けする。他フィールドは copyWith で確実に
    // 引き継ぐ（手写しだと foundedAt 等の新規フィールドを取りこぼす）。
    final enriched = instance.copyWith(
      softwareName: softwareName,
      foundedAt: mulukhiya?.foundedAt,
      preopenedAt: mulukhiya?.preopenedAt,
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
      results.add(
        await _check('Mastodon', () async {
          final body = await adapter.client.checkHealth();
          // ⚠ HTML は口が無いぶんを受け皿が返したもの（#1337・Akkoma）。
          if (looksLikeHtml(body)) throw const HealthEndpointMissing();
          return body;
        }),
      );
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
        unavailable: isHealthEndpointMissing(e),
      );
    }
  }
}

final serverInfoProvider =
    AsyncNotifierProvider.autoDispose<ServerInfoNotifier, ServerInfoState>(
      ServerInfoNotifier.new,
      dependencies: [currentAdapterProvider, currentMulukhiyaProvider],
    );

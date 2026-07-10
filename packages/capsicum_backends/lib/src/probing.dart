import 'dart:convert';

import 'package:dio/dio.dart';

import 'backend_type.dart';

const _mastodonForks = {
  'mastodon',
  'fedibird',
  'hometown',
  'glitch-soc',
  'kmyblue',
};

const _misskeyForks = {
  'misskey',
  'firefish',
  'sharkey',
  'foundkey',
  'catodon',
  'cherrypick',
  'iceshrimp',
};

BackendType? _detectBackendType(String? name) {
  if (name == null) return null;
  if (_mastodonForks.contains(name)) return BackendType.mastodon;
  if (_misskeyForks.contains(name)) return BackendType.misskey;
  return null;
}

class InstanceProbe {
  final BackendType type;

  /// nodeinfo の `software.name`（小文字）。フォークを含む生の識別子で、`type`
  /// が fedibird 等も mastodon に**マップ**するのと違い、本家名（mastodon /
  /// misskey）完全一致の判定（バージョン追従チェックのゲート等）に使える。
  final String? softwareName;
  final String? softwareVersion;

  const InstanceProbe({
    required this.type,
    this.softwareName,
    this.softwareVersion,
  });
}

Map<String, dynamic> _ensureMap(dynamic data) {
  if (data is Map<String, dynamic>) return data;
  if (data is String) return jsonDecode(data) as Map<String, dynamic>;
  throw FormatException('Unexpected response type: ${data.runtimeType}');
}

/// Probe a server to detect its backend type.
///
/// まず NodeInfo の `software.name` パターンマッチで本家 / 既知フォークを判定する。
/// これが空振り（NodeInfo が無い・未知フォーク名）したときは、特徴的なエンドポイント
/// の有無でフォールバック判定する (#723)。プリセットサーバーは NodeInfo で足りるが、
/// 未知フォークを弾かないための備え。
///
/// 全経路が失敗し、かつサーバー到達不能（接続エラー / タイムアウト）のときは
/// 例外を投げてログイン画面が「接続失敗」を出せるようにする。サーバーが応答した
/// が Mastodon / Misskey いずれとも判定できないときは `null`（＝未対応サーバー）。
Future<InstanceProbe?> probeInstance(Dio dio, String host) async {
  final viaNodeInfo = await _probeViaNodeInfo(dio, host);
  if (viaNodeInfo != null) return viaNodeInfo;
  return _probeViaEndpoints(dio, host);
}

/// NodeInfo (`/.well-known/nodeinfo` → `software.name`) で判定する。到達不能・
/// NodeInfo 未提供・未知ソフト名はすべて `null` を返し、フォールバックに委ねる。
Future<InstanceProbe?> _probeViaNodeInfo(Dio dio, String host) async {
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
    final version = software['version'] as String?;
    final type = _detectBackendType(name);
    if (type == null) return null;
    return InstanceProbe(
      type: type,
      softwareName: name,
      softwareVersion: version,
    );
  } on DioException {
    // 到達不能 / NodeInfo 未提供。フォールバックに委ねる。
    return null;
  }
}

/// 特徴的なエンドポイントの有無でフォールバック判定する (#723)。Mastodon API を
/// 備えた Misskey フォークが存在する一方その逆は無いため、Misskey (`POST /api/meta`)
/// を先に判定してから Mastodon (`GET /api/v1/instance`) を試す。
///
/// NodeInfo で本家名が取れなかった経路なので、[InstanceProbe.softwareName] は
/// あえて null にする（本家名の完全一致を要する latest 追従判定 #816 のゲートを
/// フォークで誤って点けない）。version は各 API の `version` から拾う。
Future<InstanceProbe?> _probeViaEndpoints(Dio dio, String host) async {
  var unreachable = false;

  try {
    final res = await dio.post('https://$host/api/meta', data: {});
    if (res.statusCode == 200) {
      final data = _ensureMap(res.data);
      return InstanceProbe(
        type: BackendType.misskey,
        softwareVersion: data['version'] as String?,
      );
    }
  } on DioException catch (e) {
    if (_isUnreachable(e)) unreachable = true;
  } catch (_) {
    // JSON でない等。Misskey ではないとみなし次へ。
  }

  try {
    final res = await dio.get('https://$host/api/v1/instance');
    if (res.statusCode == 200) {
      final data = _ensureMap(res.data);
      return InstanceProbe(
        type: BackendType.mastodon,
        softwareVersion: data['version'] as String?,
      );
    }
  } on DioException catch (e) {
    if (_isUnreachable(e)) unreachable = true;
  } catch (_) {
    // Mastodon でもない。
  }

  // 応答はあったが両方とも該当せず＝未対応サーバー（null）。どちらも接続自体に
  // 失敗＝到達不能なら「接続失敗」を surface する。
  if (unreachable) {
    throw Exception('サーバーに接続できません');
  }
  return null;
}

/// サーバー到達不能（接続エラー / タイムアウト）か。HTTP ステータス応答
/// (`badResponse`, 404 等) はサーバーが生きている＝未対応の判断材料なので除く。
bool _isUnreachable(DioException e) =>
    e.type == DioExceptionType.connectionError ||
    e.type == DioExceptionType.connectionTimeout ||
    e.type == DioExceptionType.receiveTimeout ||
    e.type == DioExceptionType.sendTimeout;

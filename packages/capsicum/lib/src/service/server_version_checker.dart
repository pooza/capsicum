import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../constants.dart';

/// サーバーの運用バージョンが本家 (mastodon/mastodon・misskey-dev/misskey) の
/// latest リリースに追いついているかを判定する (#815 続き)。
///
/// capsicum は**最新の Mastodon / Misskey を対象**にするため、latest に届いて
/// いないサーバーは「最新仕様でない＝一部の新機能が使えない」ことをユーザーに
/// 提示する。判定は nodeinfo の `software.name` が本家名（`mastodon` /
/// `misskey`）に**完全一致**するときだけ行う。fedibird / firefish 等、Mastodon /
/// Misskey を名乗らないフォークは対象外（不当な「古い Mastodon」表示を避ける。
/// これらは capsicum の全機能が使える保証もない別ソフトである）。
class ServerVersionChecker {
  /// 本家名 → 比較対象の GitHub リポジトリ。ここに無い software 名（fedibird 等）
  /// は判定しない。
  static const _upstreamRepos = {
    'mastodon': 'mastodon/mastodon',
    'misskey': 'misskey-dev/misskey',
  };

  /// [host] を nodeinfo で調べ、本家名一致なら本家 latest と比較して返す。
  /// 非対応ソフト / 取得失敗 / 版取得不能なら null（＝画面は追従表示を出さない）。
  static Future<ServerVersionStatus?> check(String host) async {
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: kNetworkConnectTimeout,
          receiveTimeout: kNetworkReceiveTimeout,
        ),
      );
      final probe = await probeInstance(dio, host);
      final software = probe?.softwareName;
      final version = probe?.softwareVersion;
      if (software == null || version == null) return null;
      final repo = _upstreamRepos[software];
      if (repo == null) {
        // Mastodon / Misskey を名乗らないフォーク・別ソフト。追従判定はしない。
        return ServerVersionStatus(
          software: software,
          serverVersion: version,
          latestVersion: null,
          behind: null,
        );
      }
      final latest = await _fetchLatestUpstream(dio, repo);
      return ServerVersionStatus(
        software: software,
        serverVersion: version,
        latestVersion: latest,
        behind: latest == null ? null : isBehind(version, latest),
      );
    } catch (_) {
      // 追従表示は付加情報。失敗時は静かに諦める（画面は素の版表示に戻る）。
      return null;
    }
  }

  static Future<String?> _fetchLatestUpstream(Dio dio, String repo) async {
    try {
      final res = await dio.getUri<Map<String, dynamic>>(
        Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
        options: Options(
          headers: const {'Accept': 'application/vnd.github+json'},
        ),
      );
      final tag = res.data?['tag_name'] as String?;
      return tag == null ? null : baseVersion(tag);
    } catch (_) {
      return null;
    }
  }

  /// フォーク suffix / build 番号 / 先頭 v を落とした base
  /// （例: `2025.4.1-io.12b-…` → `2025.4.1`、`v4.6.3` → `4.6.3`、`2026.6.0+0`
  /// → `2026.6.0`）。
  static String baseVersion(String raw) {
    final v = raw.startsWith('v') ? raw.substring(1) : raw;
    return v.split(RegExp(r'[-+ ]')).first;
  }

  /// [serverVersion] が [latestVersion] より古ければ true。base を dotted int で
  /// 比較し、桁数違いは欠けた桁を 0 とみなす。Mastodon の semver も Misskey の
  /// 日付版（YYYY.M.P）も同じ tuple 比較で扱える。
  @visibleForTesting
  static bool isBehind(String serverVersion, String latestVersion) =>
      !isAtLeast(serverVersion, latestVersion);

  /// [version] が [minimum] 以上か。base を dotted int で比較し、桁数違いは
  /// 欠けた桁を 0 とみなす。フォーク suffix / build 番号は [baseVersion] で
  /// 落とすため `4.6.3-bshockdon` も `4.6.3` として扱える。数値でない版
  /// （`Glitch` 等）は `[0]` に倒れるため minimum 未満と判定される。機能が
  /// 特定バージョンで追加された API のゲートに使う（例: Collections=4.6、#810）。
  static bool isAtLeast(String version, String minimum) {
    final v = _parts(version);
    final m = _parts(minimum);
    final len = v.length > m.length ? v.length : m.length;
    for (var i = 0; i < len; i++) {
      final vv = i < v.length ? v[i] : 0;
      final mv = i < m.length ? m[i] : 0;
      if (vv > mv) return true;
      if (vv < mv) return false;
    }
    return true;
  }

  static List<int> _parts(String v) =>
      baseVersion(v).split('.').map((s) => int.tryParse(s) ?? 0).toList();
}

/// サーバーの software 名と、本家 latest への追従状況 (#815 続き)。
class ServerVersionStatus {
  /// nodeinfo の software 名（小文字。例: `mastodon` / `fedibird` / `misskey`）。
  final String software;

  /// サーバーが名乗る版（nodeinfo `software.version`、生の値）。
  final String serverVersion;

  /// 本家 latest の base 版。本家名でない / 取得失敗のとき null。
  final String? latestVersion;

  /// 本家 latest より古いか。判定対象外（非本家）/ 取得失敗のとき null。
  final bool? behind;

  const ServerVersionStatus({
    required this.software,
    required this.serverVersion,
    required this.latestVersion,
    required this.behind,
  });
}

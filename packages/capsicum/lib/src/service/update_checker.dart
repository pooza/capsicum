import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../constants.dart';

/// 自動更新の無い直配ビルドの判定 (#641)。実運用では Linux AppImage の
/// ビルド (distribution/linux/appimage/build.sh) でのみ
/// `--dart-define=DIRECT_CHANNEL=true` を渡す。
///
/// ストア配布 (iOS / Android / Mac App Store / Microsoft Store) は OS が
/// 自動更新するため「新版あり」通知を出すと「手動更新できないのに毎回出る」
/// 状態になり混乱の元。Windows は Store 版と自己署名 MSIX 直配が同じ build
/// 出力を共有していて実行時に区別できないため、多数派の Store ユーザーへの
/// 誤通知を避けて全 Windows ビルドでこの define を渡さない (Linux AppImage
/// だけが「自動更新なし & 唯一の配布経路」で、ここが本機能の対象)。
const bool kIsDirectChannelBuild = bool.fromEnvironment(
  'DIRECT_CHANNEL',
  defaultValue: false,
);

/// GitHub Release API の最新タグ取得 + 現行バージョンとの semver 比較。
class UpdateChecker {
  static const _latestReleaseUrl =
      'https://api.github.com/repos/pooza/capsicum/releases/latest';

  /// 最新リリースが現行より新しければ [UpdateInfo] を返す。同等以下 / 取得
  /// 失敗 / 直配ビルドでなければ `null`。直配判定は呼び出し側で済ませる前提
  /// だが、安全側として本メソッドでも `kIsDirectChannelBuild` を gate に
  /// 含める (ストアビルドで誤って呼ばれても通知が出ないように)。
  static Future<UpdateInfo?> check() async {
    if (!kIsDirectChannelBuild) return null;
    try {
      final info = await PackageInfo.fromPlatform();
      final currentVersion = info.version;
      final dio = Dio(
        BaseOptions(
          connectTimeout: kNetworkConnectTimeout,
          receiveTimeout: kNetworkReceiveTimeout,
          headers: const {'Accept': 'application/vnd.github+json'},
        ),
      );
      final response = await dio.getUri<Map<String, dynamic>>(
        Uri.parse(_latestReleaseUrl),
      );
      final data = response.data;
      if (data == null) return null;
      final tagName = data['tag_name'] as String?;
      final htmlUrl = data['html_url'] as String?;
      if (tagName == null || htmlUrl == null) return null;
      final latestVersion = tagName.startsWith('v')
          ? tagName.substring(1)
          : tagName;
      if (!isNewer(latestVersion, currentVersion)) return null;
      return UpdateInfo(
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        releaseUrl: Uri.parse(htmlUrl),
      );
    } catch (_) {
      // 観測機構は本通知の優先度より低いので失敗時は静かに諦める。
      // 起動経路で Sentry に流すほどの実害もない。
      return null;
    }
  }

  /// 単純 semver 比較。`pubspec` の `1.30.0+85` / GitHub tag の `1.30.0` の
  /// どちらが渡されても `+` 以降は無視して dotted 数値比較する。pre-release
  /// (rc / beta 等) は capsicum では使っていないので扱わない。
  @visibleForTesting
  static bool isNewer(String latest, String current) {
    final latestParts = _parseVersion(latest);
    final currentParts = _parseVersion(current);
    final len = latestParts.length > currentParts.length
        ? latestParts.length
        : currentParts.length;
    for (var i = 0; i < len; i++) {
      final l = i < latestParts.length ? latestParts[i] : 0;
      final c = i < currentParts.length ? currentParts[i] : 0;
      if (l > c) return true;
      if (l < c) return false;
    }
    return false;
  }

  static List<int> _parseVersion(String v) {
    final base = v.split('+').first;
    return base
        .split('.')
        .map((s) => int.tryParse(s) ?? 0)
        .toList(growable: false);
  }
}

class UpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final Uri releaseUrl;

  const UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseUrl,
  });
}

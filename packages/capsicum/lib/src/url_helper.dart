export 'package:url_launcher/url_launcher.dart' show LaunchMode;

import 'package:url_launcher/url_launcher.dart';

/// HTTP/HTTPS スキームを検証してから URL を開く。
///
/// 安全でないスキーム（javascript:, file: 等）のURLは無視する。
Future<bool> launchUrlSafely(
  Uri uri, {
  LaunchMode mode = LaunchMode.platformDefault,
}) {
  if (uri.scheme != 'http' && uri.scheme != 'https') return Future.value(false);
  return launchUrl(uri, mode: mode);
}

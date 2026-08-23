import 'dart:io' show Platform;

import 'package:url_launcher/url_launcher.dart';

export 'package:url_launcher/url_launcher.dart' show LaunchMode;

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

/// 専用アプリで開きたいサービスのホスト・サフィックス表 (#755)。
///
/// 各エントリはホストの**サフィックス**として照合する（`youtube.com` は
/// `m.youtube.com` / `music.youtube.com` にも一致）。ここに URL のホストが
/// 一致すると、[launchInPreferredApp] はまず専用アプリでの起動を試みる。
/// 拡張は原則この集合への追記だけで済む。
const _preferredAppHostSuffixes = <String>{
  // YouTube（本文中で特に体験差が大きい）
  'youtube.com',
  'youtu.be',
  // Apple Music
  'music.apple.com',
  // Spotify
  'open.spotify.com',
  'spotify.link',
  // Amazon（ショッピング / Prime Video 等はアプリ側のルーティングに委ねる）
  'amazon.co.jp',
  'amazon.com',
  'amzn.to',
  'amzn.asia',
};

bool _hasPreferredApp(String host) {
  final h = host.toLowerCase();
  return _preferredAppHostSuffixes.any((s) => h == s || h.endsWith('.$s'));
}

/// 本文中の URL を、対応する専用アプリがあればそれで開く (#755)。
///
/// モバイル（iOS / Android）のみ専用アプリへの誘導を試みる。ホストが
/// [_preferredAppHostSuffixes] に一致する場合、まず
/// [LaunchMode.externalNonBrowserApplication] でネイティブアプリ起動を試み、
/// アプリ未インストール等で失敗したら [browserMode] でブラウザにフォールバック
/// する。それ以外（非対象ホスト・デスクトップ・非 http(s)）は
/// [launchUrlSafely] にそのまま流すため、既存挙動と等価。
Future<bool> launchInPreferredApp(
  Uri uri, {
  LaunchMode browserMode = LaunchMode.platformDefault,
}) async {
  final isMobile = Platform.isIOS || Platform.isAndroid;
  if (isMobile &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      _hasPreferredApp(uri.host)) {
    try {
      final opened = await launchUrl(
        uri,
        mode: LaunchMode.externalNonBrowserApplication,
      );
      if (opened) return true;
    } catch (_) {
      // アプリ未インストール / このモード非対応。ブラウザにフォールバックする。
    }
  }
  return launchUrlSafely(uri, mode: browserMode);
}

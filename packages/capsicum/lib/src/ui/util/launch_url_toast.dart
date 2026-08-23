import 'package:flutter/material.dart';

import '../../url_helper.dart';
import '../../util/exception_scrub.dart';

/// 外部ブラウザで開き、開けなければ SnackBar で知らせる (#976)。
///
/// ⚠ **同じ SnackBar ブロックが 4 箇所に写されていた**（annict_link /
/// spotify_link / login_screen / supporter_screen）。文言を直すときに片方だけ
/// 直ると、同じ失敗の言い方が画面ごとに割れる。
///
/// ⚠ **例外もここで受ける。**[launchUrlSafely] は scheme を見て false を返す
/// だけでなく、**ハンドラ不在の端末では `launchUrl` が `PlatformException` を
/// 投げる**。呼び出し側で try を書き忘れると、外部リンクを開けないだけの話が
/// 未処理の非同期エラーになる（`supporter_screen` の特商法リンクが実際に
/// 裸だった）。
///
/// ⚠ **`messenger` は await より前に捕まえる。**起動に失敗して戻ってきた
/// ときには画面を離れていることがある。
///
/// 戻り値は開けたかどうか。呼び出し側が続きを打ち切るために使う。
///
/// 例外を Sentry へ流すかどうかは #975（例外を Sentry へ流す経路の統一）の
/// 射程。ここでは debug ログに留める。
Future<bool> launchUrlOrToast(
  BuildContext context,
  Uri uri, {
  LaunchMode mode = LaunchMode.platformDefault,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (await launchUrlSafely(uri, mode: mode)) return true;
  } catch (e) {
    // ⚠ **URI を載せない。**OAuth の認可 URL は client_id とスコープを含む。
    debugLogException('capsicum: failed to launch external url', e);
  }
  messenger.showSnackBar(const SnackBar(content: Text('ブラウザを開けませんでした')));
  return false;
}

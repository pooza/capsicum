import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// relay に登録する `device_type` の決定 (#468 / #474 / #919)。
///
/// ここで返す文字列は **relay 側の `case` 分岐のキーそのもの**
/// (`Relay::PushHelpers#push_client_for` と `Relay::AnnouncementWorker#deliver`)。
/// 勝手に綴りを変えると、登録は 200 で通るのに配送だけ黙って落ちる。
///
/// 判定を 1 か所に集めているのは、「登録する側 (どの device_type で登録するか)」
/// と「購読する側 (どの device_type に relay が配るか)」が別ファイルで独立に
/// 分岐していると、片方だけ増えたときに気づけないため。#919 は実際にその形
/// だった — relay は macos に配れるようになったのに、client 側の購読ゲートが
/// mobile 限定のまま取り残されていた。
///
/// 非対応プラットフォーム (Linux #475 / Web) では null を返す。
String? resolvePushDeviceType({
  required bool isWeb,
  required bool isIOS,
  required bool isAndroid,
  required bool isMacOS,
  required bool isWindows,
}) {
  if (isWeb) return null;
  if (isIOS) return 'ios';
  if (isAndroid) return 'android';
  if (isMacOS) return 'macos'; // APNs (iOS と同一 Auth Key・#468)
  if (isWindows) return 'windows'; // WNS raw (#474)
  return null;
}

/// 実行中のプラットフォームの `device_type`。非対応なら null。
///
/// `Platform.isXxx` は Web で投げるため、[kIsWeb] を先に見る。
String? get currentPushDeviceType => kIsWeb
    ? null
    : resolvePushDeviceType(
        isWeb: false,
        isIOS: Platform.isIOS,
        isAndroid: Platform.isAndroid,
        isMacOS: Platform.isMacOS,
        isWindows: Platform.isWindows,
      );

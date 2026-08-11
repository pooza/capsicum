import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../util/exception_scrub.dart';

/// Windows のネイティブ層 (runner) から WNS Channel URI を受け取る (#474)。
///
/// APNs / FCM と違い、Windows は OS からトークンを push されるのではなく、
/// `PushNotificationChannelManager` に URI を「要求」する pull 型のため、
/// [initialize] で取得を起動し、ネイティブが `onChannelUri` を呼んできた
/// 時点で [deviceToken] / [onTokenChanged] に反映する。
///
/// Channel URI は MSIX / Microsoft Store 版（パッケージ ID あり）でのみ
/// 払い出される。非 MSIX 起動・取得失敗時は null のままになり、push 登録は
/// noDeviceToken 扱いで「対象外」に倒れる。
class WnsService {
  static const _channel = MethodChannel('capsicum/wns');

  static String? _channelUri;
  static final _tokenController = StreamController<String>.broadcast();

  /// 直近に取得した WNS Channel URI。未取得 / 取得失敗時は null。
  /// capsicum-relay はこの URI を device token とみなす。
  static String? get deviceToken => _channelUri;

  /// 新しい Channel URI を受け取るたびに emit するブロードキャストストリーム。
  /// 起動時の初回取得と、URI 失効に伴う再取得 (#474 フェーズ2 以降) の両方で
  /// 発火する。
  static Stream<String> get onTokenChanged => _tokenController.stream;

  /// ネイティブからの `onChannelUri` を待ち受け、Channel URI の取得を起動する。
  /// アプリ起動時に 1 度だけ呼ぶ（runApp 前に handler を張ってから要求する）。
  static void initialize() {
    _channel.setMethodCallHandler(_handleMethod);
    // 要求自体は非同期（ネイティブが MTA ワーカーで取得 → onChannelUri）。
    // ここでブロックせず投げっぱなしにし、結果はストリームで受ける。
    _channel.invokeMethod<void>('requestChannelUri').catchError((Object e) {
      debugLogException('capsicum: push.wns: requestChannelUri failed', e);
    });
  }

  /// バックグラウンドタスク (#474 フェーズ C) が LocalState に残した観測レコード
  /// を 1 件読み出して返す（ネイティブ側が読んだら消す）。レコードが無ければ
  /// null。返り値は push_diagnostics の単一スロット JSON 文字列で、呼び出し側
  /// （main の flush）が Sentry へ吸い上げる。
  ///
  /// AppContainer の bg task は Sentry SDK もコンソールも持てず、書き込み先の
  /// LocalState は Dart の path_provider（ローミング）からは読めないため、
  /// WinRT を持つ FullTrust runner 経由でしか取り出せない。
  static Future<String?> consumePushDiagnostics() async {
    try {
      return await _channel.invokeMethod<String>('consumePushDiagnostics');
    } catch (e) {
      debugLogException('capsicum: push.wns: consumePushDiagnostics failed', e);
      return null;
    }
  }

  /// LocalState の push 鍵セット (push_keys.json) をネイティブに再同期させる
  /// (#474 フェーズ C / Option A)。ログアウト・アカウント追加など鍵セットを
  /// 変更した直後に呼ぶ。これを怠ると、アプリ完全終了中のバックグラウンド
  /// タスクがログアウト済みアカウントの古い鍵で push を復号・表示し続け、
  /// 平文の秘密鍵も次回起動まで LocalState に残る。ネイティブ側は detached
  /// スレッドで処理して即 ack するため、await はほぼ即座に返る。失敗は
  /// ベストエフォート（次回起動時の同期で回復する）として握り潰す。
  static Future<void> syncPushKeys() async {
    try {
      await _channel.invokeMethod<void>('syncPushKeys');
    } catch (e) {
      debugLogException('capsicum: push.wns: syncPushKeys failed', e);
    }
  }

  /// LocalState の通知ラベル (push_labels.json) をネイティブに再同期させる
  /// (#770)。完全終了中の bg task / 起動中の in-process 受信は Dart の
  /// shared_preferences（[NotificationLabelCache]）を読めないため、サーバー別の
  /// reblog/post カスタムラベル（リノート / リキュア！等）をここで LocalState へ
  /// 渡す。[labelsJson] は `{ "user@host": "{\"reblog\":..,\"post\":..}" }` 形式
  /// （空 = ログイン中アカウント無し → ネイティブは push_labels.json を削除）。
  /// 鍵と違い欠落しても既定ラベルで表示は続くため、失敗はベストエフォートで
  /// 握り潰す。ネイティブは detached スレッドで処理して即 ack する。
  static Future<void> syncPushLabels(String labelsJson) async {
    try {
      await _channel.invokeMethod<void>('syncPushLabels', labelsJson);
    } catch (e) {
      debugLogException('capsicum: push.wns: syncPushLabels failed', e);
    }
  }

  static Future<dynamic> _handleMethod(MethodCall call) async {
    switch (call.method) {
      case 'onChannelUri':
        final uri = call.arguments;
        if (uri is String && uri.isNotEmpty) {
          _channelUri = uri;
          _tokenController.add(uri);
          debugPrint(
            'capsicum: push.wns: channel uri received (${uri.length} chars)',
          );
        } else {
          // 取得不可（非 MSIX 起動・ネットワーク不通等）。null のまま据え置き。
          debugPrint('capsicum: push.wns: channel uri unavailable');
        }
    }
  }
}

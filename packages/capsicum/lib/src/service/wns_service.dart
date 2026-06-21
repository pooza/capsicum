import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
      debugPrint('capsicum: push.wns: requestChannelUri failed: $e');
    });
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

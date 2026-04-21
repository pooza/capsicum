import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Receives the APNs device token from the iOS native layer via MethodChannel.
///
/// The native side (AppDelegate.swift) calls `onDeviceToken` when iOS delivers
/// the token, and `onDeviceTokenError` if registration fails.
class ApnsService {
  static const _channel = MethodChannel('net.shrieker.capsicum/apns');

  static String? _deviceToken;
  static final _tokenController = StreamController<String>.broadcast();
  // AppDelegate 側で cold-start にバッファされたタップが、Flutter 側の
  // listener 登録前に吐き出されうる。broadcast stream は過去 emit を
  // 再配信しないため、listener 登録までの間は _pendingTap にキャッシュし、
  // 新規 listener が subscribe した時点で replay する。
  static Map<String, dynamic>? _pendingTap;
  static final StreamController<Map<String, dynamic>>
  _notificationTapController = StreamController<Map<String, dynamic>>.broadcast(
    onListen: () {
      final pending = _pendingTap;
      if (pending != null) {
        _pendingTap = null;
        // onListen の中から add すると再帰呼び出しになりうるので
        // microtask にずらす。subscribe は既に確立しているので
        // 次の microtask で届く。
        scheduleMicrotask(() => _notificationTapController.add(pending));
      }
    },
  );

  /// The most recently received APNs device token, or `null` if unavailable.
  static String? get deviceToken => _deviceToken;

  /// A broadcast stream that emits whenever a new device token is received.
  /// Useful for reacting to token refreshes.
  static Stream<String> get onTokenChanged => _tokenController.stream;

  /// A broadcast stream that emits when the user taps an APNs notification.
  /// Payload is the `userInfo` dictionary from the iOS notification response,
  /// which for capsicum contains the relay's custom payload (including the
  /// `account` field used for account-aware routing).
  ///
  /// Cold-start タップは listener 登録までバッファされ、初回 subscribe 時に
  /// 1 度だけ replay される（[_pendingTap]）。
  static Stream<Map<String, dynamic>> get onNotificationTap =>
      _notificationTapController.stream;

  /// Starts listening for token events from the native layer.
  /// Call once at app startup.
  static void initialize() {
    _channel.setMethodCallHandler(_handleMethod);
  }

  static Future<dynamic> _handleMethod(MethodCall call) async {
    switch (call.method) {
      case 'onDeviceToken':
        final token = call.arguments as String;
        _deviceToken = token;
        _tokenController.add(token);
        debugPrint(
          'capsicum: push.apns: device token received (${token.length} chars)',
        );
      case 'onDeviceTokenError':
        final error = call.arguments as String;
        debugPrint('capsicum: push.apns: registration failed: $error');
      case 'onNotificationTap':
        // iOS が起動 / 復帰時に通知タップを通知してくる。引数は userInfo
        // （NSDictionary<String, Any>）で、capsicum リレーが仕込む custom
        // payload（account / server / body 等）を含む。
        final args = call.arguments;
        if (args is Map) {
          final userInfo = Map<String, dynamic>.from(args);
          if (_notificationTapController.hasListener) {
            _notificationTapController.add(userInfo);
          } else {
            // listener 未登録（engine init 中の早期タップ）。バッファする。
            _pendingTap = userInfo;
          }
        }
    }
  }
}

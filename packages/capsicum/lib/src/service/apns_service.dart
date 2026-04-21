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
  static final _notificationTapController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// The most recently received APNs device token, or `null` if unavailable.
  static String? get deviceToken => _deviceToken;

  /// A broadcast stream that emits whenever a new device token is received.
  /// Useful for reacting to token refreshes.
  static Stream<String> get onTokenChanged => _tokenController.stream;

  /// A broadcast stream that emits when the user taps an APNs notification.
  /// Payload is the `userInfo` dictionary from the iOS notification response,
  /// which for capsicum contains the relay's custom payload (including the
  /// `account` field used for account-aware routing).
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
        debugPrint('APNs device token received (${token.length} chars)');
      case 'onDeviceTokenError':
        final error = call.arguments as String;
        debugPrint('APNs registration failed: $error');
      case 'onNotificationTap':
        // iOS が起動 / 復帰時に通知タップを通知してくる。引数は userInfo
        // （NSDictionary<String, Any>）で、capsicum リレーが仕込む custom
        // payload（account / server / body 等）を含む。
        final args = call.arguments;
        if (args is Map) {
          _notificationTapController.add(Map<String, dynamic>.from(args));
        }
    }
  }
}

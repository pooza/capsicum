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

  /// The most recently received APNs device token, or `null` if unavailable.
  static String? get deviceToken => _deviceToken;

  /// A broadcast stream that emits whenever a new device token is received.
  /// Useful for reacting to token refreshes.
  static Stream<String> get onTokenChanged => _tokenController.stream;

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
    }
  }
}

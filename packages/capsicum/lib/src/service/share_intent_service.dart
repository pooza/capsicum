import 'dart:async';

import 'package:flutter/services.dart';

/// Handles text shared from external apps via platform share intents.
class ShareIntentService {
  static const _channel = MethodChannel('net.shrieker.capsicum/share');

  /// Polls the native side for shared text.
  ///
  /// Returns the shared text if available, or `null`.
  /// Each call consumes the shared text so it is not returned twice.
  /// Returns `null` if the native handler is not available (e.g. iOS
  /// without Share Extension) or if the call times out.
  static Future<String?> consumeSharedText() async {
    try {
      final text = await _channel
          .invokeMethod<String>('getSharedText')
          .timeout(const Duration(seconds: 1));
      return text;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    } on TimeoutException {
      return null;
    }
  }
}

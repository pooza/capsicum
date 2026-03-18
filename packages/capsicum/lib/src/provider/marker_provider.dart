import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_manager_provider.dart';

/// Fetches markers from the server (Mastodon only).
final markersProvider = FutureProvider.autoDispose<MarkerSet?>((ref) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter == null || adapter is! MarkerSupport) return null;
  return (adapter as MarkerSupport).getMarkers();
});

/// Debounced marker saver for home timeline.
class HomeMarkerSaver {
  final Ref _ref;
  Timer? _timer;
  String? _pendingId;

  HomeMarkerSaver(this._ref);

  void save(String lastReadId) {
    _pendingId = lastReadId;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 5), _flush);
  }

  void _flush() {
    final id = _pendingId;
    if (id == null) return;
    _pendingId = null;
    final adapter = _ref.read(currentAdapterProvider);
    if (adapter is MarkerSupport) {
      (adapter as MarkerSupport).saveHomeMarker(id).catchError((Object e) {
        debugPrint('Failed to save home marker: $e');
      });
    }
  }

  void dispose() {
    if (_pendingId != null) _flush();
    _timer?.cancel();
  }
}

/// Debounced marker saver for notifications.
class NotificationMarkerSaver {
  final Ref _ref;
  Timer? _timer;
  String? _pendingId;

  NotificationMarkerSaver(this._ref);

  void save(String lastReadId) {
    _pendingId = lastReadId;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 5), _flush);
  }

  void _flush() {
    final id = _pendingId;
    if (id == null) return;
    _pendingId = null;
    final adapter = _ref.read(currentAdapterProvider);
    if (adapter is MarkerSupport) {
      (adapter as MarkerSupport).saveNotificationMarker(id).catchError(
        (Object e) {
          debugPrint('Failed to save notification marker: $e');
        },
      );
    }
  }

  void dispose() {
    if (_pendingId != null) _flush();
    _timer?.cancel();
  }
}

final homeMarkerSaverProvider = Provider.autoDispose<HomeMarkerSaver>((ref) {
  final saver = HomeMarkerSaver(ref);
  ref.onDispose(saver.dispose);
  return saver;
});

final notificationMarkerSaverProvider =
    Provider.autoDispose<NotificationMarkerSaver>((ref) {
      final saver = NotificationMarkerSaver(ref);
      ref.onDispose(saver.dispose);
      return saver;
    });

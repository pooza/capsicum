import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/exception_scrub.dart';
import 'account_manager_provider.dart';

/// Fetches markers from the server (Mastodon only).
final markersProvider = FutureProvider.autoDispose<MarkerSet?>((ref) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter == null || adapter is! MarkerSupport) return null;
  return (adapter as MarkerSupport).getMarkers();
}, dependencies: [currentAdapterProvider]);

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
        debugLogException('Failed to save home marker', e);
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
      (adapter as MarkerSupport).saveNotificationMarker(id).catchError((
        Object e,
      ) {
        debugLogException('Failed to save notification marker', e);
      });
    }
  }

  void dispose() {
    if (_pendingId != null) _flush();
    _timer?.cancel();
  }
}

/// 通知の既読を「全部」の単位で返すバックエンド向けの保存役 (#1205)。
///
/// [NotificationMarkerSaver] の Misskey 版。あちらは「見えている一番上の通知」
/// の位置を保存するが、Misskey は位置を持たないので、**一番新しい通知が
/// 見えたとき**に全既読を返す（marker も「その位置より古いものは既読」という
/// 意味なので、先頭が見えた時点の全既読は等価）。
///
/// ⚠⚠ **呼ぶ側は「実際に見えた」ときだけ [markSeen] を呼ぶこと。**取得した
/// だけで呼ぶと、WebUI の未読が黙って消える (#1045) に戻る。
class NotificationReadSaver {
  final Ref _ref;

  /// アプリが利用者に見えているか。テストで差し替える。
  final bool Function() _isAppVisible;

  Timer? _timer;
  String? _pendingId;
  NotificationReadSupport? _pendingAdapter;

  /// 最後にサーバーへ返したときの、一覧の先頭の通知。
  ///
  /// ⚠ **同じ先頭では呼び直さない。**スクロールのたびに位置の通知が来るので、
  /// これが無いと 5 秒ごとに同じ API を叩き続ける。
  String? _sentId;

  NotificationReadSaver(this._ref, {bool Function()? isAppVisible})
    : _isAppVisible = isAppVisible ?? _defaultIsAppVisible;

  static bool _defaultIsAppVisible() {
    final state = WidgetsBinding.instance.lifecycleState;
    // ⚠ `inactive` は弾かない。デスクトップでフォーカスを外しただけの窓は
    // 画面に見えている。弾くのは窓ごと見えていない状態だけ。
    return state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached;
  }

  /// 一覧の先頭の通知 [newestId] が画面に見えた。
  void markSeen(String newestId) {
    if (newestId == _sentId || newestId == _pendingId) return;
    // ⚠ アプリが裏にいる間は「見えた」ことにしない。streaming で先頭に通知が
    // 足されると位置の通知は来るが、利用者は見ていない。
    if (!_isAppVisible()) return;
    // ⚠ **アダプターは見えた時点で掴む。**`dispose` から呼ばれる `_flush` で
    // `ref.read` すると、スコープごと破棄される経路（デッキのカラムを閉じた
    // とき等）で「破棄済みの container を読んだ」と投げ、最後の 1 回を落とす。
    final adapter = _ref.read(currentAdapterProvider);
    if (adapter is! NotificationReadSupport) return;
    _pendingAdapter = adapter as NotificationReadSupport;
    _pendingId = newestId;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 5), _flush);
  }

  void _flush() {
    final id = _pendingId;
    final adapter = _pendingAdapter;
    if (id == null || adapter == null) return;
    _pendingId = null;
    _pendingAdapter = null;
    adapter
        .markAllNotificationsRead()
        .then<void>((_) {
          _sentId = id;
        })
        .catchError((Object e) {
          // ⚠ `_sentId` を進めない。次に先頭が見えたときに送り直す。
          debugLogException('Failed to mark notifications as read', e);
        });
  }

  void dispose() {
    if (_pendingId != null) _flush();
    _timer?.cancel();
  }
}

final notificationReadSaverProvider =
    Provider.autoDispose<NotificationReadSaver>((ref) {
      final saver = NotificationReadSaver(ref);
      ref.onDispose(saver.dispose);
      return saver;
    }, dependencies: [currentAdapterProvider]);

final homeMarkerSaverProvider = Provider.autoDispose<HomeMarkerSaver>((ref) {
  final saver = HomeMarkerSaver(ref);
  ref.onDispose(saver.dispose);
  return saver;
}, dependencies: [currentAdapterProvider]);

final notificationMarkerSaverProvider =
    Provider.autoDispose<NotificationMarkerSaver>((ref) {
      final saver = NotificationMarkerSaver(ref);
      ref.onDispose(saver.dispose);
      return saver;
    }, dependencies: [currentAdapterProvider]);

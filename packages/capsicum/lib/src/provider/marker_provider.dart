import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/account.dart';
import '../util/exception_scrub.dart';
import 'account_manager_provider.dart';
import 'preferences_provider.dart';
import 'unified_notification_provider.dart';

/// Fetches markers from the server (Mastodon only).
final markersProvider = FutureProvider.autoDispose<MarkerSet?>((ref) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter == null || adapter is! MarkerSupport) return null;
  return (adapter as MarkerSupport).getMarkers();
}, dependencies: [currentAdapterProvider]);

/// Debounced marker saver for home timeline.
///
/// ⚠ **アダプターは [save] の時点で掴む** (#1235)。`dispose` から呼ばれる
/// `_flush` で `ref.read` すると、スコープごと破棄される経路（デッキのカラムを
/// 閉じたとき等）で「破棄済みの container を読んだ」と投げ、最後の 1 回の保存を
/// 落とす。
class HomeMarkerSaver {
  final Ref _ref;
  Timer? _timer;
  String? _pendingId;
  MarkerSupport? _pendingAdapter;

  HomeMarkerSaver(this._ref);

  void save(String lastReadId) {
    final adapter = _ref.read(currentAdapterProvider);
    if (adapter is! MarkerSupport) return;
    _pendingAdapter = adapter as MarkerSupport;
    _pendingId = lastReadId;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 5), _flush);
  }

  void _flush() {
    final id = _pendingId;
    final adapter = _pendingAdapter;
    if (id == null || adapter == null) return;
    _pendingId = null;
    _pendingAdapter = null;
    adapter.saveHomeMarker(id).catchError((Object e) {
      debugLogException('Failed to save home marker', e);
    });
  }

  void dispose() {
    if (_pendingId != null) _flush();
    _timer?.cancel();
  }
}

/// Debounced marker saver for notifications.
///
/// ⚠ アダプターを [save] の時点で掴む理由は [HomeMarkerSaver] と同じ (#1235)。
///
/// ⚠⚠ **古いほうへは戻さない**（リリース前レビュー・2026-10-10）。サーバーは
/// 未読の数を「この位置より新しい通知」で数える（#1207 のバッジが読む）ので、
/// 一覧を下へ読み進めた位置をそのまま保存すると、**読んだばかりの通知が
/// 未読として数え直される**（30 件目まで読んで離れると、バッジが 29 になる）。
/// 保存するのは「これまでに見えた一番新しい通知」。
class NotificationMarkerSaver {
  final Ref _ref;
  Timer? _timer;
  String? _pendingId;
  MarkerSupport? _pendingAdapter;

  /// これまでに見えた（またはサーバーが持っていた）一番新しい位置と、
  /// それがどのアカウントのものか。
  String? _highId;
  MarkerSupport? _highAdapter;

  NotificationMarkerSaver(this._ref);

  /// サーバーが持っている位置を知らせる。これより古い位置は保存しない。
  ///
  /// ⚠ **先に予約されていた保存も、これより新しくなければ取り消す**（PR #1256 の
  /// Codex P2）。サーバーの位置を引くのは非同期なので、その前に一覧の位置の
  /// 通知が来て、古い位置が予約されていることがある。
  void noteServerMarker(String lastReadId) {
    final adapter = _ref.read(currentAdapterProvider);
    if (adapter is! MarkerSupport) return;
    final pending = _pendingId;
    if (pending != null &&
        identical(adapter, _pendingAdapter) &&
        !isNewerNotificationId(pending, than: lastReadId)) {
      _timer?.cancel();
      _pendingId = null;
      _pendingAdapter = null;
      // ⚠ 取り消したぶんを「これまでの位置」から外す（下で上書きする）。
      _highId = null;
    }
    _raise(adapter as MarkerSupport, lastReadId);
  }

  void save(String lastReadId) {
    final adapter = _ref.read(currentAdapterProvider);
    if (adapter is! MarkerSupport) return;
    if (!_raise(adapter as MarkerSupport, lastReadId)) return;
    _pendingAdapter = adapter as MarkerSupport;
    _pendingId = lastReadId;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 5), _flush);
  }

  /// [id] がこれまでの位置より新しければ覚えて true。
  /// ⚠ アカウントが替わったら（アダプターが別物なら）数え直す。
  bool _raise(MarkerSupport adapter, String id) {
    final high = _highId;
    if (identical(adapter, _highAdapter) &&
        high != null &&
        !isNewerNotificationId(id, than: high)) {
      return false;
    }
    _highAdapter = adapter;
    _highId = id;
    return true;
  }

  void _flush() {
    final id = _pendingId;
    final adapter = _pendingAdapter;
    if (id == null || adapter == null) return;
    _pendingId = null;
    _pendingAdapter = null;
    adapter.saveNotificationMarker(id).catchError((Object e) {
      debugLogException('Failed to save notification marker', e);
    });
  }

  void dispose() {
    if (_pendingId != null) _flush();
    _timer?.cancel();
  }
}

/// 通知の ID の新旧（[NotificationMarkerSaver]）。
///
/// Mastodon の通知の ID は数字の文字列で、新しいほど大きい。⚠ 桁が違うと
/// 文字列の比較では逆になるので、数として比べる。
/// ⚠ **数として読めない ID は「新しい」に倒す**（保存を止めるより、従来どおり
/// 保存するほうが害が小さい）。
@visibleForTesting
bool isNewerNotificationId(String id, {required String than}) {
  final a = BigInt.tryParse(id);
  final b = BigInt.tryParse(than);
  if (a == null || b == null) return id != than;
  return a > b;
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
    _timer = Timer(const Duration(seconds: 5), _flushIfStillVisible);
  }

  /// 一覧の先頭が画面から外れた。まだ返していなければ、返すのをやめる。
  ///
  /// ⚠⚠ **待っている 5 秒のあいだに条件が変わる**（リリース前レビュー・
  /// 2026-10-10）。先頭を見てすぐ下へ読み進めた人に、その間に届いた新着まで
  /// 既読にしていた（全既読なので、見ていない通知も巻き込む・#1045 と同じ結果）。
  /// ⚠ 次に先頭が見えたときに [markSeen] が改めて予約する。
  void unsee() {
    _timer?.cancel();
    _pendingId = null;
    _pendingAdapter = null;
  }

  /// 間引きの時間が来た。⚠ **その間にアプリが裏へ回っていたら返さない**
  /// （裏にいる間に届いた新着を巻き込む）。戻ってきて先頭が見えれば予約し直す。
  void _flushIfStillVisible() {
    if (!_isAppVisible()) {
      unsee();
      return;
    }
    _flush();
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

/// 「すべての通知」で見た通知の既読を、アカウントごとに返す保存役 (#1291)。
///
/// 通知タブの [NotificationMarkerSaver] / [NotificationReadSaver] は「現在の
/// アカウント」に縛られているので、複数アカウントの通知を混ぜて出す画面では
/// 使えない。ここは**行が持つアカウント**のアダプターで返す。
///
/// - **あるアカウントの一番新しい通知の行が見えたら**、そのアカウントについて
///   返す。Mastodon はマーカー（その通知より古いものは既読）、Misskey は全既読
///   （#1205 と同じ）。⚠ ほかのアカウントの行しか見えていないうちは返さない
///   （見ていない通知を既読にしない・#1045）
/// - 通知タブと同じく 5 秒待ってから返す。その間に行が画面から外れたら、または
///   アプリが裏へ回っていたら返さない
///
/// ⚠⚠ **返す直前にサーバーの状態を確かめる**（#1291 のリリース前レビュー）。
/// 「すべての通知」は開いたときの 1 ページを出したままで、新着が入らない。
/// - Mastodon: サーバーの既読位置がこれより新しければ返さない（通知タブで先まで
///   読んだあとに、古い位置へ戻すとバッジの未読が増える）
/// - Misskey: 全既読は位置を持たないので、**サーバーの一番新しい通知がこの行と
///   同じとき**だけ返す。開いたあとに届いた、まだ見ていない通知を巻き込まない
///
/// ⚠⚠ 以前は「すべての通知」で見ても既読が返らず、2.1（#1207）でバッジに
/// サーバーの未読数を出すようになってから、ほかのアカウントのバッジを 0 に
/// する手段が「切り替えて通知タブを見る」しか無かった。
class UnifiedNotificationReadSaver {
  UnifiedNotificationReadSaver({
    bool Function()? isAppVisible,
    NotificationQuery Function()? query,
  }) : _isAppVisible =
           isAppVisible ?? NotificationReadSaver._defaultIsAppVisible,
       _query = query ?? (() => const NotificationQuery());

  final bool Function() _isAppVisible;

  /// 一覧を引いたときと同じ絞り込み（Misskey の突き合わせに使う）。
  final NotificationQuery Function() _query;

  /// アカウント（保存用のキー）ごとの、返すのを待っている予約。
  final _pending = <String, ({String id, Timer timer})>{};

  /// アカウントごとの、最後に返した通知。⚠ 同じ通知では返し直さない。
  final _sent = <String, String>{};

  /// [account] の一番新しい通知 [newestId] の行が見えた。
  ///
  /// ⚠ 予約中に別の通知で呼ばれたら（取り直して先頭が替わった）、予約し直す。
  void seen(Account account, String newestId) {
    final key = account.key.toStorageKey();
    if (_sent[key] == newestId || _pending[key]?.id == newestId) return;
    if (!_isAppVisible()) return;
    final adapter = account.adapter;
    if (adapter is! MarkerSupport && adapter is! NotificationReadSupport) {
      return;
    }
    _pending.remove(key)?.timer.cancel();
    // ⚠ 絞り込みは見えた時点で確定させる（送る頃には画面が破棄されていることがある）。
    final query = _query();
    _pending[key] = (
      id: newestId,
      timer: Timer(const Duration(seconds: 5), () {
        _pending.remove(key);
        if (!_isAppVisible()) return;
        _send(adapter, key, newestId, query);
      }),
    );
  }

  /// [account] の通知 [newestId] の行が画面から外れた。まだ返していなければやめる。
  ///
  /// ⚠ **予約が同じ通知のときだけ取り消す。**取り直しで行が入れ替わると、
  /// 古い行の「外れた」が新しい行の「見えた」より後に届くことがある。
  void unseen(Account account, String newestId) {
    final key = account.key.toStorageKey();
    if (_pending[key]?.id != newestId) return;
    _pending.remove(key)?.timer.cancel();
  }

  Future<void> _send(
    Object adapter,
    String key,
    String newestId,
    NotificationQuery query,
  ) async {
    try {
      if (adapter is MarkerSupport) {
        final server = (await adapter.getMarkers()).notifications?.lastReadId;
        if (server == null || isNewerNotificationId(newestId, than: server)) {
          await adapter.saveNotificationMarker(newestId);
        }
      } else if (adapter is NotificationReadSupport &&
          adapter is NotificationSupport) {
        // ⚠⚠ 一覧と同じ件数で引いて、先頭を比べる（2 回目のレビュー）。Misskey の
        // グループ化した取得は、束ねたグループの id がグループで一番古い通知の
        // id になる。1 件だけ引くと束ねる相手がいないので、新着が無くても
        // 一致しなかった（既定のグループ化 ON で、全既読がほぼ返らない）。
        final latest = await (adapter as NotificationSupport).getNotifications(
          query: const TimelineQuery(limit: kUnifiedNotificationPageSize),
          filter: query,
        );
        final latestId = latest.notifications.firstOrNull?.id;
        // ⚠ 空の応答（手元で絞るサーバーで先頭が除外種別だった等）は、本当に
        // 新着が無いのか区別できないので返さない（2 回目のレビュー）。
        if (latestId != newestId) return;
        await adapter.markAllNotificationsRead();
      } else {
        return;
      }
      _sent[key] = newestId;
    } catch (e) {
      // ⚠ `_sent` を進めない。次に見えたときに送り直す。
      debugLogException('Failed to mark unified notifications as read', e);
    }
  }

  /// ⚠ 予約は捨てる（5 秒見えていなかったものは返さない）。
  void dispose() {
    for (final pending in _pending.values) {
      pending.timer.cancel();
    }
    _pending.clear();
  }
}

final unifiedNotificationReadSaverProvider =
    Provider.autoDispose<UnifiedNotificationReadSaver>((ref) {
      final saver = UnifiedNotificationReadSaver(
        query: () => NotificationQuery(
          excludeTypes: ref.read(notificationExcludedTypesProvider),
          grouped: ref.read(notificationGroupingProvider),
        ),
      );
      ref.onDispose(saver.dispose);
      return saver;
    });

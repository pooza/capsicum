import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// 挿入順を保つ上限つきキー集合 (#960)。
///
/// 上限超過時に [Set.clear] で**全消し**すると、直前まで覚えていたキーまで一斉に
/// 失う。何が壊れるかは持ち主によって違うが、いずれも「覚えていたはずのことを
/// 忘れる」型:
///
/// - 表示済み dedup（`DesktopNotificationDispatcher`）— 遅れて届いた同一通知が
///   「未出」と判定されて**二重表示**になる
/// - 配信済み掃除（`DeliveredPushCleaner`）— 掃除対象と分からなくなり、
///   **通知センターに残骸が残る**
///
/// 全消しをやめ、上限を超えたぶんだけ**最古から押し出す**（FIFO）ことで、直近の
/// キーは常に保持する。macOS ネイティブ側の対応物は
/// `macos/Runner/NotificationDedupPlugin.swift`（#983）で、**同じ挙動に揃える**。
///
/// ⚠ **LRU ではなく FIFO。** 参照しても位置は変わらない。ネイティブ側と挙動を
/// 揃えるためで、片方だけ LRU にすると「同じキーなのに OS 側とアプリ側で
/// 覚えている期間が違う」になる。
class BoundedKeySet {
  BoundedKeySet(this._name, this._maxSize);

  final String _name;
  final int _maxSize;

  /// Dart の `Set` リテラルは `LinkedHashSet` で挿入順を保つため、`first` が
  /// 最古のキーになる。
  final Set<String> _keys = {};

  /// 上限超過で押し出した累計件数（観測用）。
  int dropped = 0;

  /// 押し出しを Sentry へ報告済みか。
  ///
  /// ⚠ **1 プロセスにつき 1 回だけ送る。** 知りたいのは「この上限で足りているか」で、
  /// 一度あふれた後は毎回あふれ続けるため、件数ぶん送ると同じ事実でノイズになる。
  bool _reported = false;

  int get length => _keys.length;

  bool get isEmpty => _keys.isEmpty;

  bool contains(String key) => _keys.contains(key);

  /// [key] を追加し、新規なら true を返す（`Set.add` と同じ意味）。上限を超えた
  /// ぶんは最古から押し出す。
  bool add(String key) {
    final added = _keys.add(key);
    var evicted = 0;
    while (_keys.length > _maxSize) {
      _keys.remove(_keys.first);
      dropped++;
      evicted++;
    }
    if (evicted > 0) _onEvicted(evicted);
    return added;
  }

  /// 押し出しの観測。
  ///
  /// ⚠ **debugPrint（= release では breadcrumb）だけでは足りない** (#982)。
  /// breadcrumb は**別のイベントが Sentry へ送られたときに添付される**ものなので、
  /// エラーの起きていない端末では件数がまったく出てこない。上限に達したかどうかは
  /// まさに「平常運転の端末」で知りたい値なので、初回だけ独立したイベントにする。
  void _onEvicted(int evicted) {
    debugPrint(
      'capsicum: push.desktop: dedup "$_name" evicted $evicted oldest '
      '(size=${_keys.length}/$_maxSize, total_dropped=$dropped)',
    );
    if (_reported) return;
    _reported = true;
    unawaited(
      Sentry.captureMessage(
        'push.dedup.evicted',
        level: SentryLevel.info,
        withScope: (scope) {
          scope.setTag('phase', 'push_dedup');
          // ⚠ キーそのものは載せない（`username@host|id` を含む）。
          scope.setTag('dedup.set', _name);
          scope.setContexts('dedup', {'max_size': _maxSize});
        },
      ),
    );
  }
}

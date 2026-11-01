import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

/// 操作が途切れてから再開したかを覚える (#1306)。
///
/// ⚠ 再開のあとの**最初の投稿だけ**確かめるための印で、投稿先を確かめるか、
/// 投稿が終わるまで立ったままになる。
class PostAccountIdleTracker {
  PostAccountIdleTracker({
    this.threshold = const Duration(minutes: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration threshold;
  final DateTime Function() _now;

  DateTime? _lastActivity;

  /// ⚠ 起動直後も立てる。起動も「再開」で、投稿先を間違えやすい場面そのもの。
  bool _pending = true;

  bool get pending => _pending;

  void noteActivity() {
    final now = _now();
    final last = _lastActivity;
    if (last != null && now.difference(last) >= threshold) _pending = true;
    _lastActivity = now;
  }

  void clear() => _pending = false;

  bool _started = false;

  /// アプリ全体の入力を見始める。⚠ 投稿フォームはデッキの上に積む別の画面なので、
  /// デッキの画面だけを見ていると、書いている間の操作を取りこぼす。
  void start() {
    if (_started) return;
    _started = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute((event) {
      if (event is PointerDownEvent) noteActivity();
    });
    HardwareKeyboard.instance.addHandler((_) {
      noteActivity();
      return false;
    });
  }
}

/// アプリ全体で 1 つ。
final postAccountIdleTracker = PostAccountIdleTracker();

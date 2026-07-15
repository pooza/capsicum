import 'dart:math' as math;

import 'package:flutter/material.dart';

/// サポートする MFM アニメーション種別 (#259)。
///
/// 変形（回転 / 移動 / 拡縮）と色相回転で近似できるものだけを対象にする。
/// Misskey の CSS キーフレームを厳密には再現せず、雰囲気を合わせる方針
/// （本家 mfm.js 参照実装に倣いつつ Flutter の Transform で表現）。
/// パーティクルを撒く `sparkle` は変形では表現できないためスコープ外（呼び出し
/// 側で静止表示にフォールバックする）。
enum MfmAnimationType {
  spin,
  bounce,
  jump,
  shake,
  twitch,
  jelly,
  tada,
  rainbow,
}

/// MFM のアニメーション構文（`$[bounce ...]` 等）を再生する widget (#259)。
///
/// 各インスタンスが単一の繰り返し [AnimationController] を持ち、
/// [AnimatedBuilder] で種別に応じた変形を [child] に与える。OS の「視差効果を
/// 減らす」(reduce motion) が有効なときはアニメーションせず [child] をそのまま
/// 出す（再生可否の設定判定は呼び出し側）。
class MfmAnimation extends StatefulWidget {
  const MfmAnimation({
    super.key,
    required this.type,
    required this.child,
    required this.fontSize,
    this.speed,
    this.reverse = false,
  });

  final MfmAnimationType type;
  final Widget child;

  /// 移動量の基準となるフォントサイズ（px）。
  final double fontSize;

  /// 1 周の長さ。null なら種別ごとの既定値。
  final Duration? speed;

  /// spin の逆回転（`.left`）。
  final bool reverse;

  @override
  State<MfmAnimation> createState() => _MfmAnimationState();
}

class _MfmAnimationState extends State<MfmAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  Duration get _defaultSpeed => switch (widget.type) {
    MfmAnimationType.spin => const Duration(milliseconds: 1500),
    MfmAnimationType.bounce => const Duration(milliseconds: 750),
    MfmAnimationType.jump => const Duration(milliseconds: 750),
    MfmAnimationType.shake => const Duration(milliseconds: 500),
    MfmAnimationType.twitch => const Duration(milliseconds: 500),
    MfmAnimationType.jelly => const Duration(milliseconds: 1000),
    MfmAnimationType.tada => const Duration(milliseconds: 1000),
    MfmAnimationType.rainbow => const Duration(milliseconds: 1000),
  };

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.speed ?? _defaultSpeed,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // アクセシビリティの「視差効果を減らす」設定を尊重して静止表示する。
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value; // 0.0 → 1.0
        return switch (widget.type) {
          MfmAnimationType.rainbow => ColorFiltered(
            colorFilter: _hueRotation(t * 2 * math.pi),
            child: child,
          ),
          _ => Transform(
            alignment: Alignment.center,
            transform: _transformFor(widget.type, t),
            child: child,
          ),
        };
      },
      child: widget.child,
    );
  }

  Matrix4 _transformFor(MfmAnimationType type, double t) {
    final fs = widget.fontSize;
    final tau = 2 * math.pi;
    switch (type) {
      case MfmAnimationType.spin:
        final dir = widget.reverse ? -1.0 : 1.0;
        return Matrix4.rotationZ(t * tau * dir);
      case MfmAnimationType.jump:
        // 1 周に 1 回、上へ跳ねて戻る。
        return Matrix4.translationValues(
          0,
          -fs * 0.5 * math.sin(t * math.pi),
          0,
        );
      case MfmAnimationType.bounce:
        // jump より低く跳ね、着地で軽く潰す。
        final dy = -fs * 0.3 * math.sin(t * math.pi);
        final squash = 1 - 0.1 * math.cos(t * math.pi).clamp(0.0, 1.0);
        return Matrix4.translationValues(0, dy, 0)
          ..scaleByDouble(1.0, squash, 1.0, 1.0);
      case MfmAnimationType.shake:
        final dx = fs * 0.08 * math.sin(t * tau * 3);
        final dy = fs * 0.08 * math.cos(t * tau * 2);
        return Matrix4.translationValues(dx, dy, 0)
          ..rotateZ(0.05 * math.sin(t * tau * 5));
      case MfmAnimationType.twitch:
        // shake より速く大きい痙攣。
        final dx = fs * 0.12 * math.sin(t * tau * 8);
        final dy = fs * 0.12 * math.cos(t * tau * 6);
        return Matrix4.translationValues(dx, dy, 0);
      case MfmAnimationType.jelly:
        final s = 0.15 * math.sin(t * tau);
        return Matrix4.diagonal3Values(1 + s, 1 - s, 1);
      case MfmAnimationType.tada:
        final scale = 1 + 0.1 * math.sin(t * tau);
        return Matrix4.diagonal3Values(scale, scale, 1)
          ..rotateZ((3 * math.pi / 180) * math.sin(t * tau * 3));
      case MfmAnimationType.rainbow:
        return Matrix4.identity();
    }
  }

  /// 色相を [angle] ラジアンだけ回転させる ColorFilter（rainbow 用）。標準的な
  /// hue-rotate 行列。
  ColorFilter _hueRotation(double angle) {
    final c = math.cos(angle);
    final s = math.sin(angle);
    // luminance 係数を使った一般的な hue-rotate。alpha は素通し。
    return ColorFilter.matrix(<double>[
      0.213 + c * 0.787 - s * 0.213,
      0.715 - c * 0.715 - s * 0.715,
      0.072 - c * 0.072 + s * 0.928,
      0,
      0,
      0.213 - c * 0.213 + s * 0.143,
      0.715 + c * 0.285 + s * 0.140,
      0.072 - c * 0.072 - s * 0.283,
      0,
      0,
      0.213 - c * 0.213 - s * 0.787,
      0.715 - c * 0.715 + s * 0.715,
      0.072 + c * 0.928 + s * 0.072,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ]);
  }
}

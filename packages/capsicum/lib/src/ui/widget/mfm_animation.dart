import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// サポートする MFM アニメーション種別 (#259)。
///
/// 変形（回転 / 移動 / 拡縮）で近似できるものだけを対象にする。Misskey の CSS
/// キーフレームを厳密には再現せず、雰囲気を合わせる方針（本家 mfm.js 参照実装に
/// 倣いつつ Flutter の Transform で表現）。色を巡回させる `rainbow` は変形では
/// 表現できないため [MfmRainbowText] が別に扱う。パーティクルを撒く `sparkle` は
/// 変形でも前景色でも表現できないためスコープ外（呼び出し側で静止表示にフォール
/// バックする）。
enum MfmAnimationType { spin, bounce, jump, shake, twitch, jelly, tada }

/// アニメーション再生の共通作法をまとめた mixin。
///
/// reduce motion（「視差効果を減らす」）と画面外（#845）ではどちらもアニメーション
/// が見えないので ticker を止める、という判定を [MfmAnimation] と [MfmRainbowText]
/// で共有する。実装側は [_ticker] を提供し、`didChangeDependencies` で
/// [refreshReduceMotion] を呼び、build で [reduceMotion] / [visibilityKey] /
/// [handleVisibilityChanged] を使う。
mixin _MfmTickerMixin<T extends StatefulWidget> on State<T> {
  AnimationController get _ticker;

  bool _reduceMotion = false;

  /// 画面に出ているか (#845)。`cacheExtent` に生きているだけの画面外 span まで
  /// ticker を回すと、描画されないのに毎フレーム rebuild して電池を食う。
  /// **初期値は true**: 実表示ぶんが最初の可視性コールバック（既定 500ms
  /// 間隔）まで固まって見えるのを避ける。画面外ぶんはその間だけ空回りする。
  bool _visible = true;

  /// [VisibilityDetector] はインスタンスごとに安定した key を要求する。
  late final Key _visibilityKey = ValueKey(identityHashCode(this));

  bool get reduceMotion => _reduceMotion;
  Key get visibilityKey => _visibilityKey;

  /// 「視差効果を減らす」設定を読み直し、ticker の可否に反映する。設定の切り替えに
  /// もここで追従する。
  void refreshReduceMotion() {
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _syncTicker();
  }

  /// 「描画に反映される」ときだけ ticker を回す。reduce motion（静止表示）と
  /// 画面外（#845）はどちらも回しても見えないので止める。
  void _syncTicker() {
    final shouldAnimate = !_reduceMotion && _visible;
    if (shouldAnimate) {
      if (!_ticker.isAnimating) _ticker.repeat();
    } else if (_ticker.isAnimating) {
      _ticker.stop();
    }
  }

  void handleVisibilityChanged(VisibilityInfo info) {
    // VisibilityDetector のコールバックは dispose 後にも届きうる。
    if (!mounted) return;
    final visible = info.visibleFraction > 0;
    if (visible == _visible) return;
    _visible = visible;
    // 再生可否が変わるだけで見た目は変わらないので setState は不要
    // （AnimatedBuilder が controller を購読している）。
    _syncTicker();
  }
}

/// MFM の変形アニメーション構文（`$[bounce ...]` 等）を再生する widget (#259)。
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
    with SingleTickerProviderStateMixin, _MfmTickerMixin<MfmAnimation> {
  late final AnimationController _controller;

  @override
  AnimationController get _ticker => _controller;

  Duration get _defaultSpeed => switch (widget.type) {
    MfmAnimationType.spin => const Duration(milliseconds: 1500),
    MfmAnimationType.bounce => const Duration(milliseconds: 750),
    MfmAnimationType.jump => const Duration(milliseconds: 750),
    MfmAnimationType.shake => const Duration(milliseconds: 500),
    MfmAnimationType.twitch => const Duration(milliseconds: 500),
    MfmAnimationType.jelly => const Duration(milliseconds: 1000),
    MfmAnimationType.tada => const Duration(milliseconds: 1000),
  };

  @override
  void initState() {
    super.initState();
    // 不正な speed 引数（`$[spin.speed=0s]` 等）で duration が 0 / 負になると
    // repeat() が period 0 で破綻する（debug は assert、release は NaN 変形）ため、
    // 正でなければ既定速度にフォールバックする。再生開始は didChangeDependencies。
    final speed = widget.speed ?? _defaultSpeed;
    _controller = AnimationController(
      vsync: this,
      duration: speed > Duration.zero ? speed : _defaultSpeed,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 「視差効果を減らす」(reduce motion) 時は build で child を返すだけでなく
    // ticker も止める。回し続けると描画に反映されないまま毎フレーム値を更新して
    // 電池を浪費する（reduce motion を求めた層に逆行する）。
    refreshReduceMotion();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // アクセシビリティの「視差効果を減らす」設定を尊重して静止表示する。
    // ticker は didChangeDependencies で止めてあり、可視性を見る必要もない。
    if (reduceMotion) {
      return widget.child;
    }
    return VisibilityDetector(
      key: visibilityKey,
      onVisibilityChanged: handleVisibilityChanged,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final t = _controller.value; // 0.0 → 1.0
          return Transform(
            alignment: Alignment.center,
            transform: _transformFor(widget.type, t),
            child: child,
          );
        },
        child: widget.child,
      ),
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
    }
  }
}

/// MFM の `$[rainbow ...]` を再生する widget (#259, #864)。
///
/// v1.48（#259）では hue-rotate の [ColorFilter] で実装していたが、hue 回転は
/// 彩度のある色にしか効かず、無彩色（デフォルト色）の本文テキストでは見た目が
/// 変わらなかった（#864）。そこで **テキストには時間で流れる虹グラデーションを
/// 前景色（`TextStyle.foreground` のシェーダ）として直接与え**、無彩色でも虹色に
/// 見えるようにする。
///
/// 一方、カスタム絵文字などの [WidgetSpan] は虹グラデでシルエット化させず、従来
/// どおり hue-rotate で色相だけ回す（テキストのみグラデ・絵文字は hue-rotate 維持
/// の方針）。このためグラデ適用はまとめての [ShaderMask] ではなく span 単位で行う。
class MfmRainbowText extends StatefulWidget {
  const MfmRainbowText({
    super.key,
    required this.spans,
    required this.baseStyle,
    this.speed,
  });

  /// `$[rainbow ...]` の中身（テキストとカスタム絵文字等が混在しうる）。
  final List<InlineSpan> spans;

  /// [Text.rich] のルートスタイル。前景シェーダを乗せて全テキストに継承させる。
  final TextStyle baseStyle;

  /// 1 周の長さ。null なら既定値。
  final Duration? speed;

  @override
  State<MfmRainbowText> createState() => _MfmRainbowTextState();
}

class _MfmRainbowTextState extends State<MfmRainbowText>
    with SingleTickerProviderStateMixin, _MfmTickerMixin<MfmRainbowText> {
  static const Duration _defaultSpeed = Duration(milliseconds: 1000);

  late final AnimationController _controller;

  @override
  AnimationController get _ticker => _controller;

  @override
  void initState() {
    super.initState();
    // MfmAnimation と同じく、0 / 負の speed は repeat() の period 0 破綻を避けて
    // 既定速度へフォールバックする。
    final speed = widget.speed ?? _defaultSpeed;
    _controller = AnimationController(
      vsync: this,
      duration: speed > Duration.zero ? speed : _defaultSpeed,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    refreshReduceMotion();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // reduce motion 時はアニメーションを止めるが、虹色そのものは乗せる（無彩色
    // テキストを虹色にするのが #864 の目的。動かないだけで色は付く）。
    if (reduceMotion) {
      return _buildRainbow(0);
    }
    return VisibilityDetector(
      key: visibilityKey,
      onVisibilityChanged: handleVisibilityChanged,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => _buildRainbow(_controller.value),
      ),
    );
  }

  Widget _buildRainbow(double t) {
    final textPaint = Paint()..shader = _rainbowShader(t);
    return Text.rich(
      TextSpan(
        children: [
          for (final span in widget.spans) _rainbowSpan(span, textPaint, t),
        ],
      ),
      style: widget.baseStyle.copyWith(foreground: textPaint),
    );
  }
}

/// 虹グラデを前景色に持つよう span を作り替える。テキスト（[TextSpan]）には
/// [textPaint] を前景色として与え、[WidgetSpan]（カスタム絵文字等）は hue-rotate
/// で色相だけ回す (#864)。
InlineSpan _rainbowSpan(InlineSpan span, Paint textPaint, double t) {
  if (span is TextSpan) {
    // copyWith(foreground:) は結果の color を null にするため、色付きの装飾テキスト
    // でも color/foreground 二重指定の assert に当たらない。
    return TextSpan(
      text: span.text,
      style: (span.style ?? const TextStyle()).copyWith(foreground: textPaint),
      children: span.children == null
          ? null
          : [
              for (final child in span.children!)
                _rainbowSpan(child, textPaint, t),
            ],
      recognizer: span.recognizer,
      mouseCursor: span.mouseCursor,
      onEnter: span.onEnter,
      onExit: span.onExit,
      semanticsLabel: span.semanticsLabel,
      locale: span.locale,
      spellOut: span.spellOut,
    );
  }
  if (span is WidgetSpan) {
    return WidgetSpan(
      alignment: span.alignment,
      baseline: span.baseline,
      style: span.style,
      child: ColorFiltered(
        colorFilter: _hueRotation(t * 2 * math.pi),
        child: span.child,
      ),
    );
  }
  return span;
}

/// 虹 1 周期の分割数。色相をこの数だけ等間隔に刻んで一周させる。
const int _rainbowSegments = 7;

/// 虹 1 周期分の色（HSV の色相を等間隔に一周）。末尾が先頭と同色になり、
/// [TileMode.repeated] で継ぎ目なくループする。
final List<Color> _rainbowColors = List<Color>.unmodifiable([
  for (var i = 0; i <= _rainbowSegments; i++)
    HSVColor.fromAHSV(1, (360.0 * i / _rainbowSegments) % 360, 1, 1).toColor(),
]);

/// [_rainbowColors] に対応する等間隔の stops。`ui.Gradient.linear` は colorStops を
/// 省くと colors を 2 色に限る仕様なので、3 色以上では明示する必要がある。
final List<double> _rainbowStops = List<double>.unmodifiable([
  for (var i = 0; i <= _rainbowSegments; i++) i / _rainbowSegments,
]);

/// 時刻 [t]（0.0→1.0）に応じて横へ流れる虹グラデーションのシェーダ。1 周期の幅
/// ぶんだけ平行移動し、`t=1` で `t=0` と一致するので継ぎ目なくループする。
ui.Shader _rainbowShader(double t) {
  const period = 140.0; // 虹 1 周期の幅（px）
  final shift = t * period;
  return ui.Gradient.linear(
    Offset(shift, 0),
    Offset(shift + period, 0),
    _rainbowColors,
    _rainbowStops,
    TileMode.repeated,
  );
}

/// 色相を [angle] ラジアンだけ回転させる ColorFilter（rainbow 内の絵文字用）。
/// 標準的な hue-rotate 行列。
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

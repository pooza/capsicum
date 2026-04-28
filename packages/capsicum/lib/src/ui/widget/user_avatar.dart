import 'dart:math' as math;

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';

class UserAvatar extends ConsumerWidget {
  final User user;
  final double size;
  final double borderRadius;
  final bool compact;

  const UserAvatar({
    super.key,
    required this.user,
    required this.size,
    this.borderRadius = 6,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final decorations = user.avatarDecorations;
    final showCatEars = user.isCat;
    // compact: デコレーション用パディングを省略しアバターサイズを維持
    final padding = decorations.isEmpty || compact ? 0.0 : size * 0.25;
    final totalSize = size + padding * 2;

    // Misskey 由来のユーザーは丸アバターで表示する (#371)。猫耳・アイコン
    // デコの座標計算が丸アバター前提のため、user 本人の所属に合わせる。
    // 判定:
    // - user.isCat == true → Misskey 確定（Mastodon に isCat はない）
    // - else → リモートユーザーの所属種別を確実に判定する手段がないため、
    //   操作中の adapter (currentAdapterProvider) にフォールバックする。
    //   結果として、Misskey ログイン中はほぼ全アバターが丸、Mastodon
    //   ログイン中は基本角丸で isCat true のリモートだけ丸になる。
    // 形状切替設定は #372 (v1.22) で別途扱う。
    final adapter = ref.watch(currentAdapterProvider);
    final isMisskeyUser = user.isCat || adapter is ReactionSupport;
    final effectiveBorderRadius = isMisskeyUser ? size / 2 : borderRadius;

    final avatar = ClipRRect(
      borderRadius: BorderRadius.circular(effectiveBorderRadius),
      child: user.avatarUrl != null
          ? Image.network(
              user.avatarUrl!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _fallback(context),
            )
          : _fallback(context),
    );

    if (decorations.isEmpty && !showCatEars) {
      return avatar;
    }

    return SizedBox(
      width: totalSize,
      height: totalSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 猫耳はアバターの後ろに描画（耳の付け根がアバターで隠れる）
          if (showCatEars) _CatEarWidget(avatarSize: size, padding: padding),
          Positioned(left: padding, top: padding, child: avatar),
          for (final decoration in decorations)
            _buildDecoration(decoration, size, padding),
        ],
      ),
    );
  }

  Widget _fallback(BuildContext context) {
    return Container(
      width: size,
      height: size,
      color: Theme.of(context).colorScheme.primaryContainer,
      alignment: Alignment.center,
      child: Text(
        user.username[0].toUpperCase(),
        style: TextStyle(fontSize: size * 0.4),
      ),
    );
  }

  static Widget _buildDecoration(
    AvatarDecoration decoration,
    double avatarSize,
    double padding,
  ) {
    final decoSize = avatarSize * 2.0;
    Widget image = Image.network(
      decoration.url,
      width: decoSize,
      height: decoSize,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );

    if (decoration.flipH) {
      image = Transform.flip(flipX: true, child: image);
    }

    if (decoration.angle != 0) {
      image = Transform.rotate(
        angle: decoration.angle * 2 * math.pi,
        child: image,
      );
    }

    // Misskey Web では left: (-50 + offsetX)% — 親要素(アバター)サイズに対する割合
    final offsetX = decoration.offsetX / 100 * avatarSize;
    final offsetY = decoration.offsetY / 100 * avatarSize;

    return Positioned(
      left: padding + (avatarSize - decoSize) / 2 + offsetX,
      top: padding + (avatarSize - decoSize) / 2 + offsetY,
      child: IgnorePointer(child: image),
    );
  }
}

/// Misskey の isCat 猫耳描画。
///
/// Misskey Web (MkAvatar.vue) の CSS を Flutter に移植:
/// - 左耳: rotate(37.5deg) skew(30deg), border-radius: 25% 75% 75%
/// - 右耳: rotate(-37.5deg) skew(-30deg), border-radius: 75% 25% 75% 75%
/// - 内側ピンク: 60% サイズ、#df548f
class _CatEarWidget extends StatelessWidget {
  final double avatarSize;
  final double padding;

  const _CatEarWidget({required this.avatarSize, required this.padding});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _CatEarPainter(avatarSize: avatarSize, padding: padding),
        ),
      ),
    );
  }
}

class _CatEarPainter extends CustomPainter {
  final double avatarSize;
  final double padding;

  _CatEarPainter({required this.avatarSize, required this.padding});

  static const _outerColor = Color(0xFF9E9E9E);
  static const _innerColor = Color(0xFFDF548F);

  @override
  void paint(Canvas canvas, Size size) {
    _paintEar(canvas, isLeft: true);
    _paintEar(canvas, isLeft: false);
  }

  void _paintEar(Canvas canvas, {required bool isLeft}) {
    final earW = avatarSize * 0.5;
    final earH = avatarSize * 0.5;

    // 耳の中心位置（アバター上端の左右 1/4 地点）
    final cx = padding + (isLeft ? avatarSize * 0.25 : avatarSize * 0.75);
    final cy = padding + avatarSize * 0.25;

    // CSS: rotate(±37.5deg) skew(±30deg) — rotate を先に適用し、次に skewX
    final rotAngle = (isLeft ? 37.5 : -37.5) * math.pi / 180;
    final skewAngle = (isLeft ? 30.0 : -30.0) * math.pi / 180;

    canvas.save();
    canvas.translate(cx, cy);

    // CSS の transform 順序: skewX * rotateZ（左から適用）
    final skew = Matrix4.identity()..setEntry(0, 1, math.tan(skewAngle));
    skew.multiply(Matrix4.rotationZ(rotAngle));
    canvas.transform(skew.storage);

    // 外側の耳
    // CSS border-radius: 左耳 25% 75% 75%（tl tr+bl br）、右耳 75% 25% 75% 75%
    final tl = isLeft ? 0.25 : 0.75;
    final tr = isLeft ? 0.75 : 0.25;
    const br = 0.75;
    final bl = isLeft ? 0.75 : 0.75;

    final outerRect = RRect.fromRectAndCorners(
      Rect.fromCenter(center: Offset.zero, width: earW, height: earH),
      topLeft: Radius.circular(earW * tl),
      topRight: Radius.circular(earW * tr),
      bottomRight: Radius.circular(earW * br),
      bottomLeft: Radius.circular(earW * bl),
    );
    canvas.drawRRect(outerRect, Paint()..color = _outerColor);

    // 内側の耳（ピンク）— 外側の 60%、中央配置
    final innerW = earW * 0.6;
    final innerH = earH * 0.6;
    final innerRect = RRect.fromRectAndCorners(
      Rect.fromCenter(center: Offset.zero, width: innerW, height: innerH),
      topLeft: Radius.circular(innerW * tl),
      topRight: Radius.circular(innerW * tr),
      bottomRight: Radius.circular(innerW * br),
      bottomLeft: Radius.circular(innerW * bl),
    );
    canvas.drawRRect(innerRect, Paint()..color = _innerColor);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CatEarPainter old) =>
      avatarSize != old.avatarSize || padding != old.padding;
}

import 'dart:math' as math;

import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';

class UserAvatar extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final decorations = user.avatarDecorations;
    // compact: デコレーション用パディングを省略しアバターサイズを維持
    final padding =
        decorations.isEmpty || compact ? 0.0 : size * 0.25;
    final totalSize = size + padding * 2;

    final avatar = ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
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

    if (decorations.isEmpty) {
      return avatar;
    }

    return SizedBox(
      width: totalSize,
      height: totalSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
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
    final decoSize = avatarSize * 1.5;
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
        angle: decoration.angle * math.pi / 180,
        child: image,
      );
    }

    final offsetX = decoration.offsetX * avatarSize;
    final offsetY = decoration.offsetY * avatarSize;

    return Positioned(
      left: padding + (avatarSize - decoSize) / 2 + offsetX,
      top: padding + (avatarSize - decoSize) / 2 + offsetY,
      child: IgnorePointer(child: image),
    );
  }
}

import 'package:capsicum/src/ui/widget/user_avatar.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UserAvatar.decorationOffset (#1357)', () {
    AvatarDecoration decoration({double offsetX = 0, double offsetY = 0}) {
      return AvatarDecoration(
        id: 'id',
        url: 'https://example.com/deco.webp',
        offsetX: offsetX,
        offsetY: offsetY,
      );
    }

    test('上限の 0.25 で、アバターの 50% 動く（Web の translate と同じ）', () {
      expect(
        UserAvatar.decorationOffset(
          decoration(offsetX: 0.25, offsetY: -0.25),
          48,
        ),
        const Offset(24, -24),
      );
    });

    test('調整していなければ動かない', () {
      expect(UserAvatar.decorationOffset(decoration(), 48), Offset.zero);
    });
  });
}

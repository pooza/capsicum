import 'package:capsicum_core/capsicum_core.dart';
import 'package:test/test.dart';

/// 添付の読み込み中に敷く色 (#1186)。
void main() {
  group('blurhashAverageColor', () {
    test('3〜6 文字目（base83 の 4 桁）を sRGB の平均色として読む', () {
      // 公式の例。'HV6n' = ((17*83+31)*83+6)*83+49 = 9934485 = 0x979695。
      expect(blurhashAverageColor('LEHV6nWB2yk8pyo0adR*.7kCMdnj'), 0xFF979695);
    });

    test('短すぎる・base83 に無い文字・null は読まない', () {
      expect(blurhashAverageColor(null), isNull);
      expect(blurhashAverageColor('LEHV6'), isNull);
      expect(blurhashAverageColor('LE HV6nWB2yk8'), isNull);
    });

    test('24 bit を超える値は読まない', () {
      // '~~~~' = 82*83^3+… は 0xFFFFFF を超える。
      expect(blurhashAverageColor('LE~~~~WB2yk8'), isNull);
    });
  });

  group('cssRgbColor', () {
    test('Misskey の avgColor（rgb(r,g,b)）を読む', () {
      expect(cssRgbColor('rgb(18,52,86)'), 0xFF123456);
      expect(cssRgbColor('rgb( 255 , 0 , 128 )'), 0xFFFF0080);
    });

    test('rgba も先頭 3 つを読む', () {
      expect(cssRgbColor('rgba(1,2,3,0.5)'), 0xFF010203);
    });

    test('形が違えば読まない', () {
      expect(cssRgbColor(null), isNull);
      expect(cssRgbColor('#123456'), isNull);
      expect(cssRgbColor('rgb(300,0,0)'), isNull);
    });
  });
}

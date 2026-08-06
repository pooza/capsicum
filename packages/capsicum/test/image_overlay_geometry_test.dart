import 'package:capsicum/src/ui/util/image_overlay_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

/// スタンプ (#883) の寸法計算を固定する。
///
/// このエディタは同じレイヤを編集用キャンバス（画面に fit 表示）と書き出し用
/// Canvas（原寸）の 2 回描く。両者が同じ式を通ることが WYSIWYG の唯一の担保
/// なので、式そのものと「基準高さを変えても相対的な見た目が変わらない」性質を
/// テストで留める。
void main() {
  group('stickerOverlayRect', () {
    test('高さは sizeFrac × 基準高、幅はアスペクト比から復元する', () {
      final rect = stickerOverlayRect(
        center: const Offset(100, 200),
        sizeFrac: 0.25,
        aspect: 2.0,
        referenceHeight: 400,
      );

      expect(rect.height, 100);
      expect(rect.width, 200);
      expect(rect.center, const Offset(100, 200));
    });

    test('縦長の素材でも縦横比が保たれる', () {
      final rect = stickerOverlayRect(
        center: Offset.zero,
        sizeFrac: 0.5,
        aspect: 0.5,
        referenceHeight: 200,
      );

      expect(rect.height, 100);
      expect(rect.width, 50);
    });

    // 編集画面 (表示高) と書き出し (原寸高) の一致。ここが崩れると「見たまま
    // 出ない」に直結する。
    test('基準高さが変わっても、相対的な位置と大きさは一致する', () {
      const nx = 0.3;
      const ny = 0.75;
      const sizeFrac = 0.2;
      const aspect = 1.6;

      // 編集画面: 画像を高さ 300 に fit 表示している想定。
      const displayHeight = 300.0;
      const displayWidth = displayHeight * 4 / 3;
      final preview = stickerOverlayRect(
        center: const Offset(nx * displayWidth, ny * displayHeight),
        sizeFrac: sizeFrac,
        aspect: aspect,
        referenceHeight: displayHeight,
      );

      // 書き出し: 同じ画像の原寸が高さ 1200（表示の 4 倍）。
      const fullHeight = 1200.0;
      const fullWidth = fullHeight * 4 / 3;
      final exported = stickerOverlayRect(
        center: const Offset(nx * fullWidth, ny * fullHeight),
        sizeFrac: sizeFrac,
        aspect: aspect,
        referenceHeight: fullHeight,
      );

      const scale = fullHeight / displayHeight;
      expect(exported.width, closeTo(preview.width * scale, 1e-9));
      expect(exported.height, closeTo(preview.height * scale, 1e-9));
      expect(exported.center.dx, closeTo(preview.center.dx * scale, 1e-9));
      expect(exported.center.dy, closeTo(preview.center.dy * scale, 1e-9));
    });

    test('中心を画像の端に置いても矩形はその中心を保つ（クランプしない）', () {
      // 位置のクランプは呼び出し側 (ドラッグ処理) の責務で、寸法計算は素直に
      // 中心を保つ。はみ出しは Canvas 側でクリップされる。
      final rect = stickerOverlayRect(
        center: const Offset(0, 0),
        sizeFrac: 0.5,
        aspect: 1.0,
        referenceHeight: 100,
      );

      expect(rect.center, Offset.zero);
      expect(rect.left, -25);
      expect(rect.top, -25);
    });
  });
}

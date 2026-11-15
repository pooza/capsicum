import 'dart:io';
import 'dart:ui' show Size;

import 'package:capsicum/src/service/window_state_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1385: Linux でウィンドウの最小サイズが効かず、いくらでも縮められた。
///
/// window_manager の `minimumSize` は GdkWindow に直接書くので、GTK の
/// クライアント側装飾（ヘッダーバー）のウィンドウでは GtkWindow に書き直されて
/// 残らない。runner で Flutter のビューに `gtk_widget_set_size_request` を
/// 付けて止め、復元の側でも [WindowStateService.minSize] より小さい値を切る。
///
/// ⚠ **最小サイズを C++ と Dart の 2 か所に持つ**ので、揃っていることを
/// ここで確かめる。
void main() {
  /// runner のソースから、Flutter のビューに付けた最小サイズを読む。
  /// コメントの中の記述は数えない。無ければ null。
  Size? viewSizeRequest(String source) {
    final match = RegExp(
      r'gtk_widget_set_size_request\(\s*GTK_WIDGET\(\s*view\s*\)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)',
    ).firstMatch(maskComments(source));
    if (match == null) return null;
    return Size(double.parse(match[1]!), double.parse(match[2]!));
  }

  group('runner の最小サイズ', () {
    final runner = File('linux/runner/my_application.cc');

    test('走査の対象が実在する', () {
      expect(runner.existsSync(), isTrue, reason: 'runner の場所が変わった');
    });

    test('Flutter のビューに、Dart と同じ最小サイズを付けている', () {
      expect(
        viewSizeRequest(runner.readAsStringSync()),
        WindowStateService.minSize,
        reason:
            '⚠ null なら runner で最小サイズを付けていない（#1385 の再発）。'
            '値が違うなら、C++ と Dart の片方だけを変えた',
      );
    });

    test('判定: 当たる形と、当たってはいけない形', () {
      expect(
        viewSizeRequest(
          'gtk_widget_set_size_request(GTK_WIDGET(view), 640, 480);',
        ),
        const Size(640, 480),
      );
      expect(
        viewSizeRequest(
          'gtk_widget_set_size_request(\n    GTK_WIDGET(view),\n    800, 600);',
        ),
        const Size(800, 600),
        reason: '改行を挟んだ書き方も拾う',
      );
      expect(
        viewSizeRequest(
          '// gtk_widget_set_size_request(GTK_WIDGET(view), 640, 480);',
        ),
        isNull,
        reason: 'コメントアウトしたものは数えない',
      );
      expect(
        viewSizeRequest(
          'gtk_widget_set_size_request(GTK_WIDGET(header_bar), 640, 480);',
        ),
        isNull,
        reason: 'ビュー以外に付けても効かない（ウィンドウの最小は子から計算される）',
      );
    });
  });

  group('復元する大きさ', () {
    test('保存が無ければ既定の大きさ', () {
      expect(
        WindowStateService.restoreSizeFor(null, null),
        const Size(1024, 768),
      );
      expect(
        WindowStateService.restoreSizeFor(800, null),
        const Size(1024, 768),
      );
    });

    test('最小サイズ以上ならそのまま', () {
      expect(WindowStateService.restoreSizeFor(800, 600), const Size(800, 600));
      expect(
        WindowStateService.restoreSizeFor(640, 480),
        WindowStateService.minSize,
      );
    });

    test('⚠ 最小サイズより小さく保存されていたら、最小サイズまで広げる', () {
      // #1385 の実測値（縮めると 202×101 で保存されていた）。
      expect(
        WindowStateService.restoreSizeFor(202, 101),
        WindowStateService.minSize,
      );
      expect(
        WindowStateService.restoreSizeFor(1200, 101),
        const Size(1200, 480),
        reason: '足りない辺だけを広げる',
      );
      expect(WindowStateService.restoreSizeFor(202, 900), const Size(640, 900));
    });
  });
}

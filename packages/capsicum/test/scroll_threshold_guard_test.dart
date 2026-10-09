import 'dart:io';

import 'package:capsicum/src/ui/util/scroll_thresholds.dart';
import 'package:capsicum/src/ui/util/stream_connection_display.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';
import 'support/source_files.dart';

/// #1235: 画面ごとに写されていた定数と表示が、正本へ寄ったままであること。
///
/// - 追加読み込みのしきい値 `maxScrollExtent - 600` は 17 画面に名前無しで
///   写されていた
/// - ライブ更新の接続状態の色とラベルは 2 画面に写され、既に食い違っていた
void main() {
  /// しきい値を数字で直接引いている形。改行をまたいでも当たる。
  final rawThreshold = RegExp(r'maxScrollExtent\s*-\s*\d');

  List<File> uiSources() => sourceFiles('lib/src/ui');

  group('追加読み込みのしきい値', () {
    test('走査が空振りしていない', () {
      final files = uiSources();
      expect(files.length, greaterThan(100));
      final users = files
          .where((f) => f.readAsStringSync().contains('shouldLoadMore('))
          .length;
      // 正本 1 + 置き換えた 17 画面。
      expect(users, greaterThanOrEqualTo(18), reason: '置き換え後の形が見当たらない');
    });

    test('判定は、置き換え前の形に当たり、置き換え後の形に当たらない', () {
      expect(
        rawThreshold.hasMatch(
          'if (_scrollController.position.pixels >=\n'
          '        _scrollController.position.maxScrollExtent - 600) {',
        ),
        isTrue,
      );
      expect(
        rawThreshold.hasMatch('position.maxScrollExtent-400'),
        isTrue,
        reason: '別の数字で写し直した形も拾う',
      );
      expect(
        rawThreshold.hasMatch(
          'position.maxScrollExtent - kLoadMoreScrollThreshold',
        ),
        isFalse,
      );
      expect(rawThreshold.hasMatch('if (shouldLoadMore(position)) {'), isFalse);
    });

    test('⚠ しきい値を数字で直接引いている画面が無い', () {
      final offenders = [
        for (final f in uiSources())
          if (rawThreshold.hasMatch(maskComments(f.readAsStringSync()))) f.path,
      ];
      expect(
        offenders,
        isEmpty,
        reason: 'shouldLoadMore() を使う（`ui/util/scroll_thresholds.dart`）',
      );
    });

    test('判定そのもの: 末尾の手前 600 から読みに行く', () {
      expect(kLoadMoreScrollThreshold, 600);
      expect(kNearTopScrollThreshold, 200);
    });
  });

  group('ライブ更新の接続状態の表示', () {
    testWidgets('全状態に色とラベルがあり、exhausted はテーマの error 色', (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );

      for (final state in StreamConnectionState.values) {
        expect(streamConnectionDisplay(context, state).label, isNotEmpty);
      }
      expect(
        streamConnectionDisplay(context, StreamConnectionState.exhausted).color,
        Theme.of(context).colorScheme.error,
        reason: 'デッキ側は Colors.red を直書きしていて食い違っていた',
      );
      expect(streamConnectionTooltip('接続中…'), 'ライブ更新: 接続中…');
    });

    test('⚠ 2 画面とも正本を通しており、ラベルを自前で持っていない', () {
      for (final path in [
        'lib/src/ui/widget/deck_column_view.dart',
        'lib/src/ui/screen/home_screen.dart',
      ]) {
        final src = File(path).readAsStringSync();
        expect(
          src,
          contains('streamConnectionDisplay('),
          reason: '$path が正本を通していない',
        );
        expect(
          src,
          contains('streamConnectionTooltip('),
          reason: '$path のツールチップに前置きが無い',
        );
        expect(
          src,
          isNot(contains("'ライブ更新中'")),
          reason: '$path がラベルを自前で持っている（写しが戻った）',
        );
      }
    });
  });
}

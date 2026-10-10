import 'dart:io';

import 'package:capsicum/src/ui/widget/server_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1238: サーバーバッジの文字色は、背景（サーバーの色）の明るさで決まる。
///
/// ⚠ #1240 で見出しと同じ関数（`foregroundOnHostColor`）へ揃えたが、固定して
/// いたのは見出しと関数の境界だけだった。投稿のサーバー表示も同じ箱を手書きで
/// 写していたので、[ServerBadge] へ寄せたうえでここで固定する。
void main() {
  Future<Color?> textColor(WidgetTester tester, Color background) async {
    await tester.pumpWidget(
      MaterialApp(
        // ⚠ テーマの文字色（白系）に引きずられないこと。
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Center(
            child: ServerBadge(host: 'badge.example', color: background),
          ),
        ),
      ),
    );
    return tester.widget<Text>(find.text('badge.example')).style?.color;
  }

  testWidgets('⚠ 明るい色のサーバーでは文字を暗くする', (tester) async {
    expect(await textColor(tester, const Color(0xFFFFC1E3)), Colors.black87);
  });

  testWidgets('暗い色のサーバーでは文字を白にする', (tester) async {
    expect(await textColor(tester, const Color(0xFF3F51B5)), Colors.white);
  });

  // ⚠ 投稿タイルは単体で組み立てるテストが無いので、ソースで見る。見ているのは
  // 「サーバー表示の箱を自前で組まず、[ServerBadge] を使っていること」。
  group('投稿のサーバー表示は ServerBadge を使う', () {
    String tickerBody(String source) {
      final masked = maskComments(source);
      final start = masked.indexOf('Widget _buildInstanceTicker(');
      if (start == -1) return '';
      final end = masked.indexOf('\n  }\n', start);
      return masked.substring(start, end == -1 ? masked.length : end);
    }

    test('実物: ServerBadge を使い、文字色を自前で決めていない', () {
      final body = tickerBody(
        File('lib/src/ui/widget/post_tile.dart').readAsStringSync(),
      );
      expect(body, isNotEmpty, reason: '関数を拾えている');
      expect(body, contains('ServerBadge('));
      expect(body, isNot(contains('foregroundOnHostColor')));
      expect(body, isNot(contains('Colors.white')));
    });

    test('判定: 箱を手書きした形（直す前）は落ちる', () {
      const before = '''
  Widget _buildInstanceTicker(BuildContext context, String host) {
    return Container(
      child: Text(label, style: TextStyle(color: foregroundOnHostColor(color))),
    );
  }
''';
      final body = tickerBody(before);
      expect(body.contains('ServerBadge('), isFalse);
      expect(body.contains('foregroundOnHostColor'), isTrue);
    });

    test('判定: コメントの中の ServerBadge は数えない', () {
      const commented = '''
  Widget _buildInstanceTicker(BuildContext context, String host) {
    // ServerBadge(host: host, color: color)
    return Container();
  }
''';
      expect(tickerBody(commented).contains('ServerBadge('), isFalse);
    });
  });
}

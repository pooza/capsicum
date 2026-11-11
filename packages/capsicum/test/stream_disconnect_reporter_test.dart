import 'dart:io';

import 'package:capsicum/src/service/stream_disconnect_reporter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1378: ストリーミングの切断の記録（#788 の計器）を、アプリ全体で 1 つの
/// 窓口から間引いて送る。
///
/// ⚠⚠ 以前は購読ごとに 60 秒の間引きを持っていて、同じサーバーへのカラムの
/// 数だけ送られていた。Sentry の Errors の枠の大半をこの記録が使っていた。
void main() {
  var clock = DateTime.utc(2026, 11, 11);
  late List<StreamDisconnectEvent> sent;
  late List<double> rolls;

  StreamDisconnectReporter make({double sampleRate = 0.1}) {
    clock = DateTime.utc(2026, 11, 11);
    sent = [];
    rolls = [];
    return StreamDisconnectReporter(
      sampleRate: sampleRate,
      send: sent.add,
      now: () => clock,
      random: () => rolls.isEmpty ? 0.0 : rolls.removeAt(0),
    );
  }

  test('⚠⚠ 同じサーバーへのカラムが何本あっても、1 回の切断は 1 回だけ扱う', () {
    final reporter = make(sampleRate: 1);
    for (var i = 0; i < 5; i++) {
      reporter.report(host: 'example.com', closeCode: 1002);
    }
    expect(sent, hasLength(1));
  });

  test('間引きはホストごと（別のサーバーの切断は落とさない）', () {
    final reporter = make(sampleRate: 1);
    reporter.report(host: 'a.example', closeCode: 1002);
    reporter.report(host: 'b.example', closeCode: 1006);
    reporter.report(host: null, closeCode: null);
    expect(sent.map((e) => e.host), ['a.example', 'b.example', null]);
  });

  test('間引きの時間が過ぎれば、同じサーバーでもまた扱う', () {
    final reporter = make(sampleRate: 1);
    reporter.report(host: 'a.example', closeCode: 1002);
    clock = clock.add(const Duration(seconds: 59));
    reporter.report(host: 'a.example', closeCode: 1002);
    expect(sent, hasLength(1));
    clock = clock.add(const Duration(seconds: 1));
    reporter.report(host: 'a.example', closeCode: 1002);
    expect(sent, hasLength(2));
  });

  test('⚠⚠ 間引きを通った切断のうち、割合を超えた回は送らない', () {
    final reporter = make();
    rolls.addAll([0.05, 0.1, 0.5]);
    reporter.report(host: 'a.example', closeCode: 1002);
    reporter.report(host: 'b.example', closeCode: 1002);
    reporter.report(host: 'c.example', closeCode: 1002);
    // 0.05 < 0.1 だけ送る（0.1 ちょうどは送らない）。
    expect(sent.map((e) => e.host), ['a.example']);
  });

  test('⚠ 送らなかった回にも間引きを掛ける（送る数の上限が読める）', () {
    final reporter = make();
    rolls.addAll([0.9, 0.0]);
    reporter.report(host: 'a.example', closeCode: 1002);
    reporter.report(host: 'a.example', closeCode: 1002);
    expect(sent, isEmpty);
  });

  test('既定の割合は 1 割', () {
    expect(StreamDisconnectReporter.defaultSampleRate, 0.1);
    expect(streamDisconnectReporter.sampleRate, 0.1);
  });

  test('送る中身: close code が無ければ none・理由は有無だけ・割合を載せる', () {
    final reporter = make();
    reporter.report(host: 'a.example', closeReason: 'bye');
    reporter.report(host: 'b.example', closeCode: 1000, closeReason: '');
    expect(sent[0].closeCode, 'none');
    expect(sent[0].hasReason, isTrue);
    expect(sent[1].closeCode, '1000');
    expect(sent[1].hasReason, isFalse);
    expect(sent.every((e) => e.sampleRate == 0.1), isTrue);
  });

  /// 報告役が正しくても、購読の側が自前で Sentry へ送っていれば元へ戻る。
  group('切断の記録を、購読の側が直接 Sentry へ送っていない', () {
    const path = 'lib/src/provider/timeline_provider.dart';

    bool sendsDirectly(String src) =>
        maskComments(src).contains("'timeline.stream.disconnected'");
    bool delegates(String src) =>
        maskComments(src).contains('streamDisconnectReporter.report(');

    test(path, () {
      final src = File(path).readAsStringSync();
      expect(delegates(src), isTrue, reason: '報告役を通していない');
      expect(
        sendsDirectly(src),
        isFalse,
        reason: '購読ごとに直接送っている（カラムの数だけ飛ぶ形へ戻った）',
      );
    });

    test('判定: 直接送る形を当て、コメントの中は当てない', () {
      expect(
        sendsDirectly(
          "Sentry.captureMessage('timeline.stream.disconnected', level: x);",
        ),
        isTrue,
      );
      expect(
        sendsDirectly("// 以前は 'timeline.stream.disconnected' を直接送っていた"),
        isFalse,
      );
      expect(delegates('streamDisconnectReporter.report(host: h);'), isTrue);
      expect(
        delegates('// streamDisconnectReporter.report(host: h);'),
        isFalse,
      );
    });

    test('走査対象: 報告役の側には送る文字列が実在する（空振りしていない）', () {
      final src = File(
        'lib/src/service/stream_disconnect_reporter.dart',
      ).readAsStringSync();
      expect(sendsDirectly(src), isTrue);
    });
  });
}

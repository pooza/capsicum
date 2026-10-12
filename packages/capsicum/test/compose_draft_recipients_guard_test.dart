import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// #1264: 指名（Misskey の `specified`）の宛先が、端末内の下書きに入ること。
///
/// 保存と読み出しは `compose_draft_store_test.dart`、戻す id の選び方は
/// `direct_recipients_test.dart` が見ている。ここで見るのは**投稿画面がそれらを
/// 呼んでいること**。4 か所のどれが欠けても、ストアのテストは緑のまま:
///
/// | 欠けると | 起きること |
/// | --- | --- |
/// | 保存値に宛先が無い | 開き直すと宛先が空（元の不具合） |
/// | 足したときに保存を予約しない | 本文を打たずに離れると、足した宛先が残らない |
/// | 外したときに保存を予約しない | 外した宛先が次に開いたとき戻る |
/// | 復元で宛先を戻さない | 保存されているのに画面に出ない |
///
/// ソースを読む検査なのは、投稿画面を組み立てるにはアダプタ・アカウント・
/// 下書きのストアまで要り、宛先の 4 行を見るための足場として重すぎるため。
void main() {
  late List<String> lines;

  setUpAll(() {
    lines = File('lib/src/ui/screen/compose_screen.dart').readAsLinesSync();
  });

  /// [signature] で始まるメソッドの本体（コメントを落としたもの）。
  String bodyOf(String signature) => methodBody(lines, signature);

  test('⚠ 走査が空振りしていない（4 つのメソッドを拾えている）', () {
    for (final signature in _signatures) {
      expect(
        bodyOf(signature),
        isNotEmpty,
        reason: '$signature を見つけられない。シグネチャが変わったらこのテストも直す',
      );
    }
  });

  test('保存値に宛先を載せる', () {
    expect(savesRecipients(bodyOf(_saveDraft)), isTrue);
  });

  test('宛先を足したら保存を予約する', () {
    expect(schedulesSave(bodyOf(_addRecipients)), isTrue);
  });

  test('宛先を外したら保存を予約する', () {
    expect(schedulesSave(bodyOf(_removeRecipient)), isTrue);
  });

  test('復元で宛先を戻し、名前を取りにいく', () {
    final body = bodyOf(_restoreDraft);
    expect(restoresRecipients(body), isTrue);
  });

  test('取消で、復元で入った宛先を外す', () {
    expect(bodyOf(_undoDraftRestore), contains('_recipients.removeWhere('));
  });

  group('⚠ 判定に合成ソースを食わせる', () {
    test('保存値: 当てるべき形と、当ててはいけない形', () {
      expect(
        savesRecipients('ComposeDraft(text: t, recipientIds: [...ids]);'),
        isTrue,
      );
      // 宛先を渡していない。
      expect(savesRecipients('ComposeDraft(text: t, chosen: c);'), isFalse);
      // 文字列の中に名前があるだけ。
      expect(
        savesRecipients("ComposeDraft(text: 'recipientIds: x');"),
        isFalse,
      );
    });

    test('保存の予約: 当てるべき形と、当ててはいけない形', () {
      expect(schedulesSave('setState(() {});\n_scheduleDraftSave();'), isTrue);
      expect(schedulesSave('setState(() {});'), isFalse);
      // 呼んでいない（名前を文字列に持つだけ）。
      expect(schedulesSave("log('_scheduleDraftSave()');"), isFalse);
    });

    test('復元: 選ぶ関数と名前の取得の両方が要る', () {
      const both =
          'final ids = draftRecipientIdsToRestore(saved: s, current: c, me: m);\n'
          'for (final id in ids) { unawaited(_resolveRecipient(id)); }';
      expect(restoresRecipients(both), isTrue);
      expect(
        restoresRecipients(
          'final ids = draftRecipientIdsToRestore(saved: s, current: c, me: m);',
        ),
        isFalse,
      );
      expect(restoresRecipients('unawaited(_resolveRecipient(id));'), isFalse);
    });
  });
}

const _saveDraft = '  Future<void> _saveDraft() async {';
const _addRecipients = '  Future<void> _addRecipients() async {';
const _removeRecipient = '  void _removeRecipient(String id) {';
const _restoreDraft = '  Future<void> _restoreDraft() async {';
const _undoDraftRestore = '  void _undoDraftRestore() {';

const _signatures = [
  _saveDraft,
  _addRecipients,
  _removeRecipient,
  _restoreDraft,
  _undoDraftRestore,
];

/// [lines] から、[signature] の行で始まり `  }` の行で終わるメソッドを取り出す。
/// コメントと文字列リテラルの中身は落とす。見つからなければ空。
String methodBody(List<String> lines, String signature) {
  final start = lines.indexWhere((l) => l.trimRight() == signature);
  if (start < 0) return '';
  final end = lines.indexWhere((l) => l == '  }', start + 1);
  if (end < 0) return '';
  return maskStrings(maskComments(lines.sublist(start, end + 1).join('\n')));
}

bool savesRecipients(String body) => RegExp(
  r'ComposeDraft\([^;]*\brecipientIds\s*:',
  dotAll: true,
).hasMatch(maskStrings(body));

bool schedulesSave(String body) =>
    RegExp(r'(^|[^\w.])_scheduleDraftSave\(\)\s*;').hasMatch(maskStrings(body));

bool restoresRecipients(String body) {
  final masked = maskStrings(body);
  return masked.contains('draftRecipientIdsToRestore(') &&
      masked.contains('_resolveRecipient(');
}

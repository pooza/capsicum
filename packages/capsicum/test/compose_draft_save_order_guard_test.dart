import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 離脱時保存 (#966) が「await の後で controller を読む」形に戻っていないかの
/// 検査 (Codex P2 / PR #1013)。
///
/// `_saveDraft` は投げっぱなしで呼ばれ、**呼んだ直後に State が dispose される**
/// 経路（`PopScope` / ライフサイクル）が本命。await をまたいでから
/// `_controller.text` を読むと破棄済み ChangeNotifier に触れて落ち、`mounted` で
/// 抜ける形にすると**唯一の保存機会を捨てる**（書きかけがそのまま消える）。
///
/// 実際 PR #1013 では、取消の消去との直列化 (`await _draftClearing`) を保存値の
/// 確定より前に置いてしまい、その後の `if (!mounted) return` で離脱時保存が
/// 捨てられる形になっていた。順序そのものを固定する。
///
/// ソースを読む検査なのは、この経路が「dispose の直前に発火して、dispose の後も
/// 走り続ける」タイミングでしか現れないため。widget test では
/// `tester.pumpWidget` の破棄と保存の in-flight を狙って重ねられない。
void main() {
  test('_saveDraft は await より前に ComposeDraft を確定させる', () {
    final lines = File(
      'lib/src/ui/screen/compose_screen.dart',
    ).readAsStringSync().split('\n');

    final start = lines.indexWhere(
      (l) => l.trimRight() == '  Future<void> _saveDraft() async {',
    );
    expect(start, isNot(-1), reason: '_saveDraft を見つけられない。シグネチャが変わったらこのテストも直す');
    final end = lines.indexWhere((l) => l == '  }', start + 1);
    expect(end, isNot(-1), reason: '_saveDraft の終端を見つけられない');
    // コメント行は落とす（この節は「await をまたぐ前に」と日本語で説明して
    // いるので、素朴に検索するとコメントを拾う）。
    final body = lines
        .sublist(start, end + 1)
        .where((l) => !l.trimLeft().startsWith('//'))
        .toList(growable: false);

    final snapshot = body.indexWhere((l) => l.contains('ComposeDraft('));
    final firstAwait = body.indexWhere((l) => l.contains('await '));
    expect(snapshot, isNot(-1), reason: '保存値の組み立てを拾えていない');
    expect(firstAwait, isNot(-1), reason: 'await を拾えていない');
    expect(
      snapshot,
      lessThan(firstAwait),
      reason:
          '_saveDraft が await の後で保存値を組んでいる。離脱時保存は dispose と'
          '競合するので、controller を読むのは await より前でなければならない',
    );
  });

  /// #1035-A2: ドライブ添付の ALT の書き戻しは、投稿 / 保存が**通ってから**。
  ///
  /// ⚠⚠ **ドライブファイルは実体が 1 つ。**投稿が失敗しても、そのファイルを
  /// 使っている**過去の投稿の ALT は新しい文字列のまま残る**。ユーザーには
  /// 「投稿に失敗しました」しか出ず、諦めて画面を閉じても戻らない。
  ///
  /// ⚠ **後ろへ回せるのは Misskey の仕様による。**ノートの ALT はドライブ
  /// ファイルの `comment` を**参照**するので、投稿後に書いても反映される。
  ///
  /// ソースを読む検査なのは、実際に踏むには「ドライブ添付の ALT を編集して
  /// 投稿し、その投稿だけ失敗させる」という組み合わせが要るため。
  group('ドライブ ALT の書き戻しの位置 (#1035-A2)', () {
    List<String> bodyOf(String signature) {
      final lines = File(
        'lib/src/ui/screen/compose_screen.dart',
      ).readAsStringSync().split('\n');
      final start = lines.indexWhere((l) => l.trimRight() == signature);
      expect(start, isNot(-1), reason: '$signature を見つけられない。シグネチャが変わったら直す');
      final end = lines.indexWhere((l) => l == '  }', start + 1);
      expect(end, isNot(-1), reason: '$signature の終端を見つけられない');
      // ⚠ コメント行は落とす。この節は日本語で「投稿の前に置かない」と説明して
      // いるので、素朴に検索すると自分の説明文を拾う。
      return lines
          .sublist(start, end + 1)
          .where((l) => !l.trimLeft().startsWith('//'))
          .toList(growable: false);
    }

    void expectSyncAfter(String signature, String sendCall) {
      final body = bodyOf(signature);
      final send = body.indexWhere((l) => l.contains(sendCall));
      final sync = body.indexWhere(
        (l) => l.contains('_syncDriveDescriptions()'),
      );
      expect(send, isNot(-1), reason: '$sendCall を拾えていない（検査のアンカーが外れた）');
      expect(sync, isNot(-1), reason: '_syncDriveDescriptions の呼び出しを拾えていない');
      expect(
        sync,
        greaterThan(send),
        reason:
            'ALT の書き戻しが $sendCall より前にある (#1035-A2)。'
            '失敗すると、そのドライブファイルを使っている過去の投稿の ALT だけが'
            '書き換わったまま残る',
      );
    }

    test('投稿は postStatus が通ってから書き戻す', () {
      expectSyncAfter(
        '  Future<void> _submitInternal() async {',
        'postStatus(',
      );
    });

    test('サーバー下書きは saveDraft が通ってから書き戻す', () {
      // 下書き保存の経路も同型。⚠ 片方だけ直すと非対称が残る。
      final lines = File(
        'lib/src/ui/screen/compose_screen.dart',
      ).readAsStringSync().split('\n');
      final signature = lines.firstWhere(
        (l) => l.contains('saveDraft(') && l.trimLeft().startsWith('await '),
        orElse: () => '',
      );
      expect(signature, isNotEmpty, reason: 'saveDraft の呼び出しが見つからない');

      final save = lines.indexWhere(
        (l) => l.contains('DraftSupport).saveDraft('),
      );
      final sync = lines.indexWhere(
        (l) =>
            l.contains('_syncDriveDescriptions()') &&
            !l.trimLeft().startsWith('//'),
        save,
      );
      expect(save, isNot(-1));
      expect(
        sync,
        isNot(-1),
        reason: 'saveDraft の後ろに _syncDriveDescriptions が無い (#1035-A2)',
      );
      expect(sync, greaterThan(save));
    });
  });
}

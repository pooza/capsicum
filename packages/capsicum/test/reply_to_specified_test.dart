import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #1043 の回帰テスト（リリース前レビューで検出した 🔴 2 件の再発防止）。
///
/// ⚠⚠ **一度、公開範囲を `followersOnly` へ「丸める」実装を入れて 2 通りに
/// 壊した。**その形へ戻らないことをソースで固定する。
///
/// 1. **指名への返信が必ず 400 で落ちる。**Misskey の `NoteCreateService` は
///    `reply.visibility === 'specified' && data.visibility !== 'specified'`
///    を拒否する。**指名への返信は指名でしか送れない。**
/// 2. ⚠⚠ **自分の指名ノートの redraft が DM をフォロワー全員へ広げる。**
///    返信関係が無いのでサーバーは弾かず、そのまま followers 宛に出る。
///
/// ⚠ **丸めの前提「指名は誰にも届かない」自体が誤りだった。**返信については
/// サーバーが返信先の作者を `visibleUsers` へ自動補完するので、
/// `visibleUserIds` を送らなくても**正しく届いていた**。
///
/// ウィジェットを pump せずソースの文字列で見るのは、compose_screen が
/// アダプタ・アカウント・プロバイダを揃えないと組み立てられないため
/// （`bottom_inset_guard_test.dart` と同じ流儀）。
void main() {
  final source = File(
    'lib/src/ui/screen/compose_screen.dart',
  ).readAsStringSync();

  test('公開範囲を丸める実装を復活させない', () {
    expect(
      source.contains('_clampScope'),
      isFalse,
      reason:
          '公開範囲の自動補正が復活している (#1043)。'
          '⚠ 広い範囲へ倒すと、自分の指名ノートの redraft で '
          'DM がフォロワー全員へ出る。丸めずに送信を止めること',
    );
  });

  test('送れない公開範囲は送信を止める', () {
    expect(
      source.contains('_unsendableScopeReason'),
      isTrue,
      reason: '宛先を作れない「指名」のまま送信できてしまう (#1043)',
    );
    // 判定だけあって送信経路で見ていない形を防ぐ。
    final submitIndex = source.indexOf('Future<void> _submitInternal()');
    expect(submitIndex, isNonNegative, reason: '_submitInternal が見つからない');
    final submitHead = source.substring(submitIndex, submitIndex + 1200);
    expect(
      submitHead.contains('_unsendableScopeReason'),
      isTrue,
      reason: '_submitInternal が送信前に公開範囲を検査していない (#1043)',
    );
  });

  test('返信は止めない（サーバーが宛先を補完するため）', () {
    // `widget.replyTo != null` で早期 return していること。
    final getterIndex = source.indexOf('String? get _unsendableScopeReason');
    expect(getterIndex, isNonNegative);
    final getter = source.substring(getterIndex, getterIndex + 700);
    expect(
      getter.contains('widget.replyTo != null'),
      isTrue,
      reason:
          '指名への返信まで止めている (#1043)。'
          'Misskey は返信先の作者を visibleUsers へ自動補完するので送れる',
    );
  });

  test('ピッカーは現在値を必ず含める', () {
    // items に無い値を DropdownButton に渡すと assert で落ちる。
    // 返信・redraft で「指名」が入る経路があるため必須。
    expect(
      source.contains('selectable.contains(s) || s == _scope'),
      isTrue,
      reason:
          '選択中の公開範囲がピッカーの選択肢に無い (#1043)。'
          'DropdownButton が assert で落ちる',
    );
  });
}

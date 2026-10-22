import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/service/settings_backup.dart';
import 'package:flutter_test/flutter_test.dart';

/// #857: 取り込んだ値を画面へ反映するための provider 一覧の対応検査。
///
/// [backedUpPreferenceProviders] に足し忘れると、値は SharedPreferences に
/// 書き込まれているのに**次の起動まで画面へ出ない**（読み込んだのに変わらない、
/// と見える）。1:1 対応を件数で見張る。
///
/// ⚠ 読み手が provider でない設定（起動時に 1 回読むだけ・#1317）は
/// [backedUpSettingsWithoutProvider] で明示し、件数から引く。
void main() {
  test('反映対象の provider はバックアップ対象の設定と同数', () {
    expect(
      backedUpPreferenceProviders.length,
      exportableSettings.length - backedUpSettingsWithoutProvider.length,
      reason:
          'exportableSettings と backedUpPreferenceProviders が食い違っている。'
          '設定を足したら両方に足すこと（provider が無い設定なら '
          'backedUpSettingsWithoutProvider に理由つきで足す）',
    );
  });

  test('provider を持たないと明示した設定は、バックアップ対象に実在する', () {
    // ⚠ 古い名前が残ると、件数の引き算だけが効いて別の漏れを隠す。
    expect(
      exportableSettings.map((s) => s.key),
      containsAll(backedUpSettingsWithoutProvider),
    );
  });

  test('同じ provider を二度並べていない', () {
    expect(
      backedUpPreferenceProviders.toSet().length,
      backedUpPreferenceProviders.length,
    );
  });
}

import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/service/settings_backup.dart';
import 'package:flutter_test/flutter_test.dart';

/// #857: 取り込んだ値を画面へ反映するための provider 一覧の対応検査。
///
/// [backedUpPreferenceProviders] に足し忘れると、値は SharedPreferences に
/// 書き込まれているのに**次の起動まで画面へ出ない**（読み込んだのに変わらない、
/// と見える）。1:1 対応を件数で見張る。
void main() {
  test('反映対象の provider はバックアップ対象の設定と同数', () {
    expect(
      backedUpPreferenceProviders.length,
      exportableSettings.length,
      reason:
          'exportableSettings と backedUpPreferenceProviders が食い違っている。'
          '設定を足したら両方に足すこと',
    );
  });

  test('同じ provider を二度並べていない', () {
    expect(
      backedUpPreferenceProviders.toSet().length,
      backedUpPreferenceProviders.length,
    );
  });
}

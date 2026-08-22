import 'package:capsicum/src/ui/util/settings_backup_file_type.dart';
import 'package:flutter_test/flutter_test.dart';

/// #972: 設定バックアップのファイル選択に渡す型グループ。
///
/// ⚠ **この検査が要るのは、拡張子だけの型グループが iOS で例外になるため。**
/// `file_selector_ios` は `uniformTypeIdentifiers` が空だと `openFile` で
/// `ArgumentError` を投げる（拡張子も mimeType も見ない）。デスクトップだけで
/// 動かしていた間は表に出なかったが、モバイルへ広げた時点で**読み込みが即座に
/// 落ちる**ようになる。
///
/// 逆に UTI を常時載せると、**macOS だけは 3 フィールドを和で解釈する**ため、
/// デスクトップのダイアログの絞り込みまで緩む。どちらに倒しても壊れるので、
/// 分岐していること自体を固定する。
void main() {
  test('iOS 以外は UTI を載せない（macOS の絞り込みを緩めないため）', () {
    final group = settingsBackupTypeGroup(needsUti: false);

    expect(group.uniformTypeIdentifiers, anyOf(isNull, isEmpty));
    expect(group.extensions, containsAll(<String>['yaml', 'yml']));
    expect(group.mimeTypes, isNotEmpty);
  });

  test('iOS は UTI を載せる（空だと openFile が ArgumentError を投げる）', () {
    final group = settingsBackupTypeGroup(needsUti: true);

    expect(
      group.uniformTypeIdentifiers,
      isNotEmpty,
      reason: 'iOS はこれが空だと ArgumentError で読み込みが落ちる',
    );
    // 拡張子と mimeType は他 OS が見るので、UTI を足しても落とさない。
    expect(group.extensions, containsAll(<String>['yaml', 'yml']));
    expect(group.mimeTypes, isNotEmpty);
  });

  test('iOS の UTI は public.yaml を使わない（下限 iOS 15 に無いため）', () {
    final group = settingsBackupTypeGroup(needsUti: true);

    expect(
      group.uniformTypeIdentifiers,
      isNot(contains('public.yaml')),
      reason: 'public.yaml は iOS 16 以降。15 では .yaml が dyn.* になり選べなくなる',
    );
  });

  test('allowsAny にはしない（どの OS でも「全ファイル」にはならない）', () {
    // allowsAny だと各実装が絞り込みを外す。緩めるにしても UTI 側だけに留める。
    expect(settingsBackupTypeGroup(needsUti: false).allowsAny, isFalse);
    expect(settingsBackupTypeGroup(needsUti: true).allowsAny, isFalse);
  });
}

import 'package:capsicum/src/provider/account_manager_provider.dart';
import 'package:capsicum/src/provider/deck_provider.dart';
import 'package:capsicum/src/provider/server_config_provider.dart';
import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

/// #1381: デッキの間は、テーマの元の色を固定する
/// （`docs/deck-ui-decisions-2.md` 決定済み事項 18）。
///
/// ⚠ 現在のアカウントはフォーカス中のカラムと関係が無いので、その色で塗ると
/// 美食丼のカラムにフォーカスしていても帯がダイスキーの茶色になっていた。
class _Mulukhiya extends Mock implements MulukhiyaService {
  _Mulukhiya(this._hex);

  final String _hex;

  @override
  String? get themeColorHex => _hex;
}

void main() {
  ProviderContainer containerWith({required int decks}) {
    final c = ProviderContainer(
      overrides: [
        currentAccountProvider.overrideWithValue(null),
        currentMulukhiyaProvider.overrideWithValue(_Mulukhiya('#8e4d2f')),
      ],
    );
    c.read(mountedDeckCountProvider.notifier).state = decks;
    addTearDown(c.dispose);
    return c;
  }

  test('タブ UI ではサーバーの色（モロヘイヤのテーマカラー）', () {
    final c = containerWith(decks: 0);
    expect(c.read(themeSeedColorProvider), const Color(0xFF8E4D2F));
  });

  test('⚠ デッキが開いている間は固定の色', () {
    final c = containerWith(decks: 1);
    expect(c.read(themeSeedColorProvider), Colors.green);
  });

  test('⚠ デッキを閉じたらサーバーの色へ戻る', () {
    final c = containerWith(decks: 1);
    final sub = c.listen(themeSeedColorProvider, (_, _) {});
    expect(sub.read(), Colors.green);
    c.read(mountedDeckCountProvider.notifier).state = 0;
    expect(sub.read(), const Color(0xFF8E4D2F));
  });
}

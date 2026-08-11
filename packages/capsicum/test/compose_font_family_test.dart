import 'dart:async';

import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #892 followup（v1.53 リリース PR の Codex 指摘）。
///
/// [ComposeFontFamilyNotifier] は `build()` で `''` を返してから、保存値を非同期に
/// 読んで差し替える。この往復の最中に設定画面で編集すると、**後から届いた保存値が
/// ユーザーの入力を上書きする**（打った内容が黙って前の値に戻る／既定へ戻すつもりで
/// 空にしたのに古い値が復活する）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer boot(Map<String, Object> initial) {
    SharedPreferences.setMockInitialValues(initial);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // build() を走らせて非同期ロードを開始させる。
    container.listen(
      composeFontFamilyProvider,
      (_, _) {},
      fireImmediately: true,
    );
    return container;
  }

  test('保存値は読み込み後に反映される', () async {
    final container = boot({'compose_font_family': 'HackGen Console'});

    await Future<void>.delayed(Duration.zero);

    expect(container.read(composeFontFamilyProvider), 'HackGen Console');
  });

  test('読み込み中に打った値が、後から届く保存値で上書きされない', () async {
    final container = boot({'compose_font_family': '古いフォント'});

    // ロードの往復が終わる前に編集する。
    unawaited(
      container
          .read(composeFontFamilyProvider.notifier)
          .setFontFamily('新しいフォント'),
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(
      container.read(composeFontFamilyProvider),
      '新しいフォント',
      reason: '打った内容が黙って前の値に戻ってはいけない',
    );
  });

  test('読み込み中に空へ戻した場合も、古い保存値が復活しない', () async {
    final container = boot({'compose_font_family': '古いフォント'});

    // 既定へ戻すつもりで空にする。state は初期値の '' のままなので、
    // 「同じ値だから何もしない」の早期 return を踏む経路。
    unawaited(
      container.read(composeFontFamilyProvider.notifier).setFontFamily(''),
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(
      container.read(composeFontFamilyProvider),
      '',
      reason: '既定へ戻す操作を保存値の到着で巻き戻さない',
    );
  });

  test('打鍵ごとの保存はデバウンスされ、state だけ即時反映される (#927)', () async {
    final container = boot({});
    final notifier = container.read(composeFontFamilyProvider.notifier);

    // 連続打鍵を模す。state は最後の値で即時反映される。
    unawaited(notifier.setFontFamily('H'));
    unawaited(notifier.setFontFamily('Ha'));
    unawaited(notifier.setFontFamily('HackGen'));
    expect(container.read(composeFontFamilyProvider), 'HackGen');

    // デバウンス満了前は prefs へ書かれていない。
    final prefsBefore = await SharedPreferences.getInstance();
    expect(prefsBefore.getString('compose_font_family'), isNull);

    // 満了後に一度だけ最終値が書かれる。
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final prefsAfter = await SharedPreferences.getInstance();
    expect(prefsAfter.getString('compose_font_family'), 'HackGen');
  });

  test('空欄で確定するとキーごと消える (#927)', () async {
    final container = boot({'compose_font_family': 'HackGen'});
    await Future<void>.delayed(Duration.zero);
    final notifier = container.read(composeFontFamilyProvider.notifier);

    unawaited(notifier.setFontFamily(''));
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('compose_font_family'), isNull);
  });
}

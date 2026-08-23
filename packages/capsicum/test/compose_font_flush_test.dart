import 'dart:io';

import 'package:capsicum/src/provider/preferences_provider.dart';
import 'package:capsicum/src/util/shared_preferences_cache.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #976 / #1022: フォントファミリ設定のデバウンス取りこぼし。
///
/// `setFontFamily` は打鍵ごとに呼ばれるので、`prefs` への書き込みを 400ms
/// デバウンスしている (#927-2)。**その窓の中で離脱すると、書いた文字が消える。**
/// デバウンスを入れる前は即時書き込みだったので、これは #927-2 が持ち込んだ退行。
///
/// ⚠⚠ **窓は 1 つではない。**#976 は `dispose` にだけ flush を置き、doc では
/// 「アプリ終了で失われる」を動機に挙げていた。**しかし Flutter は終了時に
/// ウィジェットツリーを dispose しない**ので、設定画面を開いたまま終了する
/// 経路はまったく塞げていなかった（#1022・Codex P2）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const key = 'compose_font_family';

  Future<ProviderContainer> containerWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    initSharedPreferencesCache(await SharedPreferences.getInstance());
    return ProviderContainer();
  }

  group('保留中の書き込みを確定する', () {
    test('デバウンス待ちの値を今すぐ書く', () async {
      final container = await containerWith({});
      addTearDown(container.dispose);
      final notifier = container.read(composeFontFamilyProvider.notifier);

      await notifier.setFontFamily('HackGen Console');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(key), isNull, reason: 'ここで書けていたらデバウンスが効いていない');

      await notifier.flushPendingWrite();

      expect(prefs.getString(key), 'HackGen Console');
    });

    /// 空欄は「既定へ戻す」でキーごと消す。**flush が値を持ち回っていないと
    /// ここで取り違える**（直前の非空文字が復活する）。
    test('空欄に戻した直後でも、空欄が確定する', () async {
      final container = await containerWith({key: 'HackGen Console'});
      addTearDown(container.dispose);
      final notifier = container.read(composeFontFamilyProvider.notifier);

      await notifier.setFontFamily('');
      await notifier.flushPendingWrite();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(key), isNull);
    });

    // 保留が無いのが普通。画面を開いて何も触らず閉じるたびに書かない。
    test('保留が無ければ何も書かない', () async {
      final container = await containerWith({});
      addTearDown(container.dispose);

      await container
          .read(composeFontFamilyProvider.notifier)
          .flushPendingWrite();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isNot(contains(key)));
    });
  });

  /// 呼び出し側の配線。⚠ **widget test にできない** — `_ComposeFontSetting` は
  /// private で、デスクトップ設定画面を丸ごと pump しないと到達しない。
  /// `alt_edit_gate_source_test.dart` と同じく**ソースで固定する**。
  ///
  /// ⚠⚠ **2 つ揃っていることに意味がある。**片方だけでも「flush を呼んでいる」
  /// ようには見えるが、塞げる窓が違う。#976 は `dispose` だけで「アプリ終了」を
  /// 塞いだつもりになっていた。
  group('設定画面の配線', () {
    String source() => File(
      'lib/src/ui/screen/settings/desktop_settings_screen.dart',
    ).readAsStringSync();

    test('画面を離れる経路（dispose）で確定する', () {
      expect(
        source(),
        contains(
          'void dispose() {\n'
          '    WidgetsBinding.instance.removeObserver(this);\n'
          '    //',
        ),
        reason: 'observer を外し忘れると、破棄後の画面が flush を呼び続ける',
      );
      expect(source(), contains('_controller.dispose();'));
    });

    test('アプリ終了の経路（lifecycle）でも確定する', () {
      expect(
        source(),
        contains('void didChangeAppLifecycleState(AppLifecycleState state)'),
        reason:
            'Flutter は終了時にウィジェットツリーを dispose しないので、'
            'dispose だけでは設定画面を開いたままの終了を塞げない',
      );
      expect(
        source(),
        contains('if (state == AppLifecycleState.resumed) return;'),
        reason: 'resumed 以外はすべて離脱とみなす（#964 の下書き保存と同じ形）',
      );
    });

    test('flush の呼び出しが 2 経路ある', () {
      expect(
        'flushPendingWrite()'.allMatches(source()).length,
        2,
        reason: 'dispose と didChangeAppLifecycleState の 2 つ',
      );
    });
  });
}

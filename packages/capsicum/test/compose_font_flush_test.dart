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

  /// 呼び出し側の配線は [compose_font_flush_routes_test.dart] へ移した (#1026)。
  ///
  /// ⚠⚠ **ここにあったソース pin は、検査になっていなかった。**「`dispose` と
  /// いう文字列がファイルにある」ことしか見ておらず、**呼び出しが届くか・
  /// 保留中の値が実際に書かれるか**は一切見ていない。実害も出ていて、
  /// `dispose` の中の `ref.read` は riverpod の `_assertNotDisposed` に当たって
  /// **必ず StateError になる**（`unmount()` が `mounted` を false にしてから
  /// `dispose()` を呼ぶ）。つまり **#976 の dispose flush は一度も効いて
  /// いなかった**のに、この group は緑で通り続けていた。
  ///
  /// widget test を諦めた理由は「`_ComposeFontSetting` が private」だったが、
  /// **それを載せている `DesktopSettingsScreen` は public** なので、画面ごと
  /// pump すれば実物に到達できる。
  ///
  /// ⚠ **ソースを pin する検査を書くときは、「実物を動かせない理由」を疑うこと。**
  /// 動かせるのに諦めると、この形の空振りになる。
  test('配線の検査は実経路の widget test が持つ (#1026)', () {
    expect(
      File('test/compose_font_flush_routes_test.dart').existsSync(),
      isTrue,
      reason: 'ここから移した検査の実体。消すなら配線の検査ごと引き取ること',
    );
  });
}

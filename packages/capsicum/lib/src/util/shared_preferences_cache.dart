import 'package:shared_preferences/shared_preferences.dart';

/// main() で pre-warm した [SharedPreferences] を同期参照するためのキャッシュ。
///
/// `SharedPreferences.getInstance()` は内部キャッシュを持つが Future を返す
/// ため、`async` 関数内では必ず microtask queue に 1 度 yield する。これだと
/// `TabConfigNotifier.build()` の同期戻り後に `_load()` の `state =` が遅れて
/// 走る race (#579) を構造的には消せない。
///
/// pre-warm 済みインスタンスを同期で取れる窓口を main() に作り、
/// `build()` を完全同期化することで race window 自体を消す。
SharedPreferences? _cached;

/// main() で `await SharedPreferences.getInstance()` した結果を渡す。
void initSharedPreferencesCache(SharedPreferences prefs) {
  _cached = prefs;
}

/// pre-warm 済みインスタンスを同期で取り出す。
///
/// main() の pre-warm 経路を踏まずに呼ばれた場合 (テスト等で誤って先に provider
/// build が走った場合) は [StateError] を投げる。release ビルドの runtime path
/// では必ず先に main() が pre-warm するため発生しない設計。
SharedPreferences get sharedPrefsOrThrow {
  final prefs = _cached;
  if (prefs == null) {
    throw StateError(
      'SharedPreferences cache is not initialized. '
      'Call initSharedPreferencesCache() in main() before runApp().',
    );
  }
  return prefs;
}

/// テスト専用: キャッシュを差し替える。
///
/// プロダクションコードから呼んではいけない。
void debugSetSharedPreferencesCache(SharedPreferences? prefs) {
  _cached = prefs;
}

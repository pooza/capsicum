/// ネイティブがナウプレのジャケットを書き出さなかった理由として受け取る値
/// (#1283 / #1274)。
///
/// ⚠⚠ **iOS / macOS（`NowPlayingPlugin.swift`）と Windows（`smtc_now_playing.cpp`）の
/// 共通の受け口** (#1304)。以前は Apple Music の provider のファイルにあり、
/// Windows の provider が借りていた（受け口の関数も丸写しだった）。
/// どのネイティブが返す値も、`now_playing_apple_music_test` が突き合わせる。
const kNowPlayingArtworkSkipReasons = {
  'no_artwork',
  // iOS: 曲のファイルの埋め込みを読み出せず、OS の画像も無かった (#1293)。
  'read_failed',
  'unsupported_format',
  'too_large',
  'write_failed',
};

/// ⚠ **知っている値だけを通す。**この値はそのまま Sentry の breadcrumb に載る
/// ので、ネイティブが返した任意の文字列を素通しにしない。
String? nowPlayingArtworkSkipReason(Object? value) =>
    value is String && kNowPlayingArtworkSkipReasons.contains(value)
    ? value
    : null;

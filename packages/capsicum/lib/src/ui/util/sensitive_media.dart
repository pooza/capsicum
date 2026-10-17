/// 閲覧注意のメディアに掛けるぼかしの強さ（`ImageFilter.blur` の sigma）。
///
/// ⚠ 投稿・メディアカタログ・ギャラリーの詳細で同じ値を使う (#1293)。直すのは
/// ここだけ。重ねる文言は `contentWarningFallbackLabel`。
const kSensitiveMediaBlurSigma = 30.0;

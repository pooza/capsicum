import '../../model/privacy_settings.dart';

/// プライバシーとつながりやすさの設定を読み書きする (#1375)。
///
/// Mastodon: `GET verify_credentials` / `PATCH update_credentials`。
/// Misskey: `POST /api/i` / `POST /api/i/update`。
///
/// ⚠ 承認制・おすすめへの掲載は、以前はプロフィール編集にあった（#865）。
/// 置き場を 1 か所に揃えるためこちらへ移した（2026-11-09 pooza）。
abstract mixin class PrivacySettingsSupport {
  /// サーバーから読み直して返す。
  Future<PrivacySettings> getPrivacySettings();

  /// [changes] の**非 null の項目だけ**送る（null は変えない）。返すのは更新後。
  ///
  /// ⚠ [PrivacySettings.searchEngineEditable] が false の SNS（Mastodon）では、
  /// [PrivacySettings.searchEngineHidden] を渡しても送らない（API が無い）。
  Future<PrivacySettings> updatePrivacySettings(PrivacySettings changes);
}

/// API response DTOs for Mastodon and Misskey.
///
/// ⚠ **節コメント（`// Mastodon` / `// Misskey`）は置かない (#1027-D)。**
/// `directives_ordering` が export をパスのアルファベット順に並べ替えるので、
/// **コメントは並べ替えに追随せず、隣の行を指したまま取り残される**。実際
/// `// Mastodon` は `src/mastodon/account.dart` の**下**に落ちており、
/// `announcement.dart` を指しているように読めていた。
///
/// 区分はパス (`src/mastodon/` / `src/misskey/`) がそのまま表しているので、
/// 別の印は要らない。
library;

export 'src/mastodon/account.dart';
export 'src/mastodon/announcement.dart';
export 'src/mastodon/application.dart';
export 'src/mastodon/collection.dart';
export 'src/mastodon/list.dart';
export 'src/mastodon/media_attachment.dart';
export 'src/mastodon/notification.dart';
export 'src/mastodon/status.dart';
export 'src/mastodon/token.dart';
export 'src/misskey/announcement.dart';
export 'src/misskey/check_session_response.dart';
export 'src/misskey/drive_file.dart';
export 'src/misskey/list.dart';
export 'src/misskey/note.dart';
export 'src/misskey/notification.dart';
export 'src/misskey/user.dart';

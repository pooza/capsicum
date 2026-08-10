import 'dart:async';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';

class MulukhiyaAbout {
  final String version;
  final String controllerType;
  final String? packageUrl;

  const MulukhiyaAbout({
    required this.version,
    required this.controllerType,
    this.packageUrl,
  });
}

class AnnictWork {
  final int annictId;
  final String title;
  final int? seasonYear;
  final String? officialSiteUrl;
  final String? hashtag;
  final String? commandToot;

  const AnnictWork({
    required this.annictId,
    required this.title,
    this.seasonYear,
    this.officialSiteUrl,
    this.hashtag,
    this.commandToot,
  });
}

class AnnictEpisode {
  final int annictId;
  final String? numberText;
  final String? title;
  final String? hashtag;
  final String? url;
  final String? commandToot;

  const AnnictEpisode({
    required this.annictId,
    this.numberText,
    this.title,
    this.hashtag,
    this.url,
    this.commandToot,
  });
}

class MulukhiyaProgram {
  final String name;
  final String? series;
  final String? episode;
  final String? episodeSuffix;
  final String? subtitle;
  final bool air;
  final bool livecure;
  final int? minutes;
  final List<String> extraTags;
  // モロヘイヤ #4236 (番組表エディタ) で `annict_work_id` / `annict_episode_id`
  // を保持できるようになった (#298)。感想投稿先 Annict エピソードを直接
  // 識別するために capsicum 側でも読み取る。
  final int? annictWorkId;
  final int? annictEpisodeId;
  // 放送開始時刻 (`HH:MM`, 24 時間制) と次回放送日 (#965)。モロヘイヤ #4287 /
  // #4373 で番組表エントリが持つようになった。**`nextOn` が null の枠は「毎日」
  // 扱い**で、値の欠落ではない (`program.ics` と同じ意味づけ)。
  //
  // `/mulukhiya/api/program` は `var/program.yaml` の値をそのまま載せるため、
  // 手編集や外部データソース由来の不正値がクライアントまで届く (`program.ics`
  // は fail-closed で落とすが `/program` は落とさない)。パースできない値は
  // null に倒し、日時を出さずに従来どおり描画する。
  final String? startTime;
  final DateTime? nextOn;

  const MulukhiyaProgram({
    required this.name,
    this.series,
    this.episode,
    this.episodeSuffix,
    this.subtitle,
    this.air = false,
    this.livecure = false,
    this.minutes,
    this.extraTags = const [],
    this.annictWorkId,
    this.annictEpisodeId,
    this.startTime,
    this.nextOn,
  });
}

/// Annict 視聴記録の評価値 (#298)。
/// モロヘイヤ #4227 の `POST /api/annict/record` `rating_state` パラメタに
/// そのまま渡せる Annict GraphQL の RatingState enum と同名。
enum AnnictRatingState {
  great,
  good,
  average,
  bad;

  String get apiValue => name.toUpperCase();
}

/// モロヘイヤ `/about` の日付フィールド (`founded_at` / `preopened_at`) を
/// パースする (#4434 / capsicum#818)。モロヘイヤは ISO 8601 date (`YYYY-MM-DD`)
/// で返すため、時刻を持たないローカル日付として扱う (year/month/day 表示で日が
/// ズレない)。未設定・空・パース不能は null。
DateTime? _parseIsoDate(dynamic value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value);
}

final _programDateRe = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
final _programTimeRe = RegExp(r'^(\d{1,2}):(\d{2})$');

/// 番組表エントリの `next_on`（次回放送日, `YYYY-MM-DD`）をパースする (#965)。
///
/// [_parseIsoDate] と違い**書式を厳密に見る**。`DateTime.parse` は月末を超えた
/// 日をロールオーバーする（`2026-02-31` → `2026-03-03`）ので、素通しすると
/// 実在しない日付が「それらしい別の日」として表示されてしまう。書き込み API は
/// contract で弾くが、`var/program.yaml` の手編集と外部データソース由来の値は
/// ここまで届く。パース後に成分が一致しなければ null に倒す。
DateTime? parseProgramNextOn(dynamic value) {
  if (value is! String) return null;
  final m = _programDateRe.firstMatch(value);
  if (m == null) return null;
  final year = int.parse(m.group(1)!);
  final month = int.parse(m.group(2)!);
  final day = int.parse(m.group(3)!);
  final date = DateTime(year, month, day);
  if (date.year != year || date.month != month || date.day != day) return null;
  return date;
}

/// 番組表エントリの `start_time`（放送開始時刻）をパースし `HH:MM` に正規化する
/// (#965)。モロヘイヤは保存時に 2 桁ゼロ埋めへ正規化する (#4372) が、古い
/// エントリや手編集では `9:00` のまま残りうるのでクライアント側でも揃える。
/// 時・分が 24 時間制の範囲外なら null。
String? parseProgramStartTime(dynamic value) {
  if (value is! String) return null;
  final m = _programTimeRe.firstMatch(value);
  if (m == null) return null;
  final hour = int.parse(m.group(1)!);
  final minute = int.parse(m.group(2)!);
  if (hour > 23 || minute > 59) return null;
  return '${hour.toString().padLeft(2, '0')}:${m.group(2)}';
}

/// Extract the first default hashtag (without '#') from the about response.
String? _parseDefaultHashtag(dynamic value) {
  if (value is String && value.isNotEmpty) {
    return value.replaceFirst('#', '');
  }
  if (value is List && value.isNotEmpty) {
    return value.first.toString().replaceFirst('#', '');
  }
  return null;
}

class ServerLink {
  final String href;
  final String body;
  final String? icon;

  const ServerLink({required this.href, required this.body, this.icon});
}

class ServerLinkGroup {
  final String? title;
  final List<ServerLink> links;

  const ServerLinkGroup({this.title, required this.links});
}

class FavoriteTag {
  final String name;
  final String? url;
  final int count;

  const FavoriteTag({required this.name, this.url, required this.count});
}

/// 読み付き単語サジェスト (劇中ワード補完) の候補 1 件 (#4397 / capsicum#614)。
/// `GET /mulukhiya/api/word/suggest` のレスポンス要素。
class WordSuggestion {
  /// 挿入する表層形 (例: `閃華裂光拳`)。
  final String surface;

  /// 並べ替え・ハイライト用の読み (カタカナ)。
  final String reading;

  /// 品詞細分類 (人名 / 技名 / 作品名 / 一般 等)。辞書に列がある場合のみ付く
  /// 任意フィールド。未整備のサーバーでは null。
  final String? category;

  const WordSuggestion({
    required this.surface,
    required this.reading,
    this.category,
  });
}

/// 読みクエリの正規化（サーバー `PronunciationDictionary#normalize_reading` の
/// 実用版近似・capsicum#687）。
///
/// ユーザーが打鍵できるのはひらがな読みで、辞書側 `reading` はカタカナのため、
/// **ひらがな→カタカナ**へ寄せて突き合わせ空間を揃えるのが要点。前後空白も除く。
/// サーバーは加えて NFKC（半角カナ・互換/全角英数の畳み込み）を行うが、依存を
/// 増やさないためここでは再現しない。NFKC 相当が要る入力（半角カナ等）は
/// [MulukhiyaService.suggestWordsLocal] がサーバー `word/suggest` へ委ねて救う
/// （方針: 実用版＋サーバー fallback）。
String normalizeReadingQuery(String value) {
  final buffer = StringBuffer();
  for (final rune in value.trim().runes) {
    // ひらがな (ぁ 0x3041 – ゖ 0x3096) をカタカナ (ァ 0x30A1 – ヶ 0x30F6) へ。
    if (rune >= 0x3041 && rune <= 0x3096) {
      buffer.writeCharCode(rune + 0x60);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// 実用版正規化 ([normalizeReadingQuery]) が取りこぼす文字（サーバーの NFKC で
/// のみ畳まれる文字）をクエリが含むか。含むときだけローカル 0 件でもサーバー
/// 正規化に委ねる判断に使う（capsicum#687）。
///
/// 判定は「ローカルだけで完結できると確信できる文字」allowlist の裏返し
/// （#821）。ひらがな / カタカナ / 基本ラテン / CJK 統合漢字 / 空白は NFKC でも
/// 畳まれず、client の ひらがな→カタカナ 変換だけでサーバーと同じ突き合わせに
/// なるため、これらのみのクエリはローカル 0 件がサーバーでも 0 件で確定し
/// fallback 不要。半角カナ・全角英数・互換合成文字（例: ① → 1）などは NFKC で
/// のみ畳まれサーバーだけが救えるため fallback する。以前は U+FF00–FFEF の範囲
/// 列挙で、その外側の互換文字を取りこぼしていた。
bool queryMayNeedServerNormalization(String value) {
  for (final rune in value.trim().runes) {
    if (!_isLocallyNormalizableRune(rune)) return true;
  }
  return false;
}

/// [normalizeReadingQuery] だけでサーバー NFKC と同じ突き合わせになる（＝NFKC で
/// 畳まれない）文字か。ここに無い文字を含むクエリはサーバー正規化に委ねうる。
bool _isLocallyNormalizableRune(int rune) {
  // 空白（前後は trim 済みだが、語中空白も安全側で許容）。
  if (rune == 0x20 || rune == 0x09 || rune == 0x0A || rune == 0x0D) return true;
  // 基本ラテン（NFKC 不変。全角ラテン FF01–FF5E は畳まれるので allowlist 外）。
  if (rune >= 0x0021 && rune <= 0x007E) return true;
  // ひらがな。
  if (rune >= 0x3040 && rune <= 0x309F) return true;
  // カタカナ（長音符 ー U+30FC を含む）。
  if (rune >= 0x30A0 && rune <= 0x30FF) return true;
  // CJK 統合漢字（拡張 A / 基本面。互換漢字 U+F900–FAFF は NFKC で畳まれるため除外）。
  if (rune >= 0x3400 && rune <= 0x4DBF) return true;
  if (rune >= 0x4E00 && rune <= 0x9FFF) return true;
  return false;
}

/// 一括取得した劇中ワード辞書 [entries] を [query] でローカル絞り込みする
/// （サーバー `PronunciationDictionary#suggest` の再現・capsicum#687）。
///
/// ランク: 0=読み前方一致 / 1=表層前方一致 / 2=読み部分一致。マッチしなければ
/// 除外。同ランク内は読み（カタカナ）の辞書順 → 短い順で安定ソートし、[limit]
/// 件に丸める。サーバーと同じ並びを保つことで、都度クエリ（`word/suggest`）と
/// 体感の並びを揃える。
List<WordSuggestion> filterWordSuggestions(
  List<WordSuggestion> entries,
  String query, {
  int? limit,
}) {
  final surfaceQuery = query.trim();
  final readingQuery = normalizeReadingQuery(surfaceQuery);
  if (readingQuery.isEmpty) return const [];
  final scored = <({int rank, WordSuggestion entry})>[];
  for (final entry in entries) {
    final rank = _wordMatchRank(entry, readingQuery, surfaceQuery);
    if (rank == null) continue;
    scored.add((rank: rank, entry: entry));
  }
  scored.sort((a, b) {
    final byRank = a.rank.compareTo(b.rank);
    if (byRank != 0) return byRank;
    final byReading = a.entry.reading.compareTo(b.entry.reading);
    if (byReading != 0) return byReading;
    return a.entry.reading.length.compareTo(b.entry.reading.length);
  });
  final result = [for (final s in scored) s.entry];
  if (limit != null && limit >= 0 && limit < result.length) {
    return result.sublist(0, limit);
  }
  return result;
}

/// 候補マッチの優先度（小さいほど上位）。マッチしなければ null。
/// サーバー `match_rank` と同一: 読み前方一致 0 / 表層前方一致 1 / 読み部分一致 2。
int? _wordMatchRank(
  WordSuggestion entry,
  String readingQuery,
  String surfaceQuery,
) {
  final reading = entry.reading;
  if (reading.startsWith(readingQuery)) return 0;
  if (surfaceQuery.isNotEmpty && entry.surface.startsWith(surfaceQuery)) {
    return 1;
  }
  if (reading.contains(readingQuery)) return 2;
  return null;
}

class MediaCatalogItem {
  final String id;
  final String url;
  final String? thumbnailUrl;
  final String? createdAt;
  final String? fileName;
  final String? fileSizeStr;
  final String? type;
  final String? mediatype;
  final String? pixelSize;
  final double? duration;
  final String? accountUsername;
  final String? accountDisplayName;
  final String? statusBody;
  final String? statusPublicUrl;

  const MediaCatalogItem({
    required this.id,
    required this.url,
    this.thumbnailUrl,
    this.createdAt,
    this.fileName,
    this.fileSizeStr,
    this.type,
    this.mediatype,
    this.pixelSize,
    this.duration,
    this.accountUsername,
    this.accountDisplayName,
    this.statusBody,
    this.statusPublicUrl,
  });
}

class MediaCatalogResult {
  final List<MediaCatalogItem> items;
  final bool hasNext;

  const MediaCatalogResult({required this.items, required this.hasNext});
}

class EmojiPaletteEntry {
  final String id;
  final String name;
  final List<String> emojis;

  const EmojiPaletteEntry({
    required this.id,
    required this.name,
    required this.emojis,
  });
}

class EmojiPalettesResult {
  final List<EmojiPaletteEntry> palettes;
  final String? paletteForReaction;
  final String? paletteForMain;

  const EmojiPalettesResult({
    required this.palettes,
    this.paletteForReaction,
    this.paletteForMain,
  });

  /// Get emojis for the reaction palette (falls back to first palette).
  List<String> get reactionEmojis {
    if (paletteForReaction != null) {
      final palette = palettes
          .where((p) => p.id == paletteForReaction)
          .firstOrNull;
      if (palette != null) return palette.emojis;
    }
    return palettes.isNotEmpty ? palettes.first.emojis : const [];
  }

  /// Get emojis for the main palette (falls back to first palette).
  List<String> get mainEmojis {
    if (paletteForMain != null) {
      final palette = palettes.where((p) => p.id == paletteForMain).firstOrNull;
      if (palette != null) return palette.emojis;
    }
    return palettes.isNotEmpty ? palettes.first.emojis : const [];
  }
}

/// Spotify 連携トークンが未連携 / 失効でモロヘイヤが 403 を返したことを表す
/// (#570)。「再生中の曲なし (null)」とは区別され、呼び出し側が再連携導線を
/// 出せる状態。`Ginseng::AuthError` (HTTP 403) に対応する。
class MulukhiyaSpotifyAuthException implements Exception {
  const MulukhiyaSpotifyAuthException();

  @override
  String toString() => 'MulukhiyaSpotifyAuthException';
}

class MulukhiyaService {
  final Dio _dio;
  final String baseUrl;
  final String controllerType;
  final String version;
  final int? maxPostLength;
  final String? postLabel;
  final String? themeColorHex;
  final String? defaultHashtag;
  final String? reblogLabel;
  final bool annictEnabled;

  /// モロヘイヤ 5.23.0+ の `features.annict_linked` フラグ (#611)。
  /// サーバーの Annict 連携可否 ([annictEnabled]) とは別に、**当該ユーザーが
  /// Annict 連携済みか**を表す。`false` のユーザーには感想投稿ボタンを出さない。
  /// 旧モロヘイヤ (フラグ未提供) は連携状態を判別できないため `true` に
  /// フォールバックし、従来どおりボタンを出す (押下時に OAuth 連携を促す)。
  final bool annictLinked;

  /// `features.annict_review` フラグ (mulukhiya #4433 / capsicum#677)。感想投稿
  /// エンドポイント `/api/annict/review`（mulukhiya #4342 追加）を備えるサーバーで
  /// のみ `true`。未デプロイのサーバーでは POST が 404 になり汎用エラーだけが出る
  /// ため、`annictEnabled && annictReviewEnabled` で感想ボタンを gate する。旧
  /// モロヘイヤ (フラグ未提供) は false にフォールバックし、ボタンを出さない。
  final bool annictReviewEnabled;

  /// モロヘイヤ 5.23.0+ の `features.media_catalog` フラグ (#606)。
  /// 5.23.0 でデフォルト無効化されたため `true` の時だけメディアカタログ画面を
  /// 開ける。旧モロヘイヤ (フラグ未提供) は false にフォールバックする。
  final bool mediaCatalogEnabled;

  /// `features.announcement_push` フラグ (#477)。`true` のサーバーは capsicum-relay
  /// が `/api/v1/announcements` (または Misskey 相当) を polling して push を発火
  /// する経路に対応している。capsicum 側は probing 結果に基づき設定 UI のスイッチを
  /// 出し分け、true の時のみ subscription 登録経路を有効化する。
  final bool announcementPushEnabled;

  /// `features.word_suggest` フラグ (#4397 / capsicum#614)。`true` のサーバーは
  /// 読み付き単語辞書 (`word_suggest/urls`) を設定済みで、`word/suggest` API が
  /// 利用可能。capsicum は劇中ワードサジェスト UI の出し分けに使う。旧モロヘイヤ
  /// (フラグ未提供) は false にフォールバックし、辞書タブを出さない。
  final bool wordSuggestEnabled;

  /// `features.nowplaying_resolver` フラグ (#4382 / capsicum#669)。`true` の
  /// サーバーは enrich プロキシ (`POST nowplaying/resolve`) を提供し、URL を
  /// 持たないナウプレ源 (Apple Music / MPRIS / SMTC) のメタデータから共有 URL を
  /// 解決できる。iTunes Search は資格情報不要のためモロヘイヤ側は常に true を返す
  /// が、旧モロヘイヤ (フラグ未提供) は false にフォールバックし enrich を試みない。
  final bool nowplayingResolverEnabled;

  /// `features.nowplaying_url_resolver` フラグ (#4415 / capsicum#729)。`true` の
  /// サーバーは **URL→メタ** の逆 enrich (`POST nowplaying/resolve-url`) を提供し、
  /// 共有(Share)経路の URL しか持たないナウプレ投稿でも title/artist/album を解決
  /// して in-app と同じ整形に寄せられる。[nowplayingResolverEnabled]（メタ→URL,
  /// #669）とは逆方向の別エンドポイント。旧モロヘイヤ (フラグ未提供) は false に
  /// フォールバックし、共有は従来どおりモロヘイヤ post-time enrich に委ねる。
  final bool nowplayingUrlResolverEnabled;

  /// `features.spotify_enabled` フラグ (#4337 / capsicum#570)。`true` の
  /// サーバーは Spotify user-level OAuth (Developer Dashboard 登録 +
  /// `user_oauth_enabled`) を満たし、`spotify/*` エンドポイントが利用可能。
  /// 旧モロヘイヤ (フラグ未提供) は false にフォールバックし、ナウプレ取得導線を
  /// 出さない。
  final bool spotifyEnabled;

  /// `features.spotify_linked` フラグ (#4337 / capsicum#570)。サーバーの
  /// Spotify 提供可否 ([spotifyEnabled]) とは別に、**当該ユーザーが Spotify
  /// 連携済みか**を表す。`true` の時だけ compose のナウプレ挿入ボタンを出す
  /// (`spotify/currently_playing` が叩ける)。`annictLinked` と異なり未連携時は
  /// ボタンを出さない (連携導線は設定画面が担う) ため、欠落時は false に倒す。
  final bool spotifyLinked;

  /// `config.founded_at` (#4434 / capsicum#818)。サーバーの**正式オープン日**
  /// (本公開日)。モロヘイヤ側で `/founded_on` を手設定していればその値、未設定なら
  /// 最古ローカルアカウント作成日で近似した値がサーバー側で入る (capsicum は
  /// ヒューリスティックを持たず本値を単純採用する)。DB 未接続・取得不能なら null。
  /// 非モロヘイヤ鯖では [Instance.foundedAt] のクライアント側ヒューリスティックが
  /// 使われる。
  final DateTime? foundedAt;

  /// `config.preopened_at` (#4434 / capsicum#818)。プレ公開 (限定公開) を経た
  /// サーバーの、正式オープン前の公開開始日。`/preopened_on` を手設定した時のみ
  /// 非 null で、[foundedAt] と違い最古アカウント fallback は持たない (プレ公開の
  /// 有無は運用者しか知り得ないため)。`preopenedAt <= foundedAt` の関係になる。
  final DateTime? preopenedAt;

  /// `features.compose_templates` フラグ (#4457 / capsicum#767)。`true` の
  /// サーバーは投稿テンプレートの per-user CRUD (`compose/templates`) を提供する。
  /// 旧モロヘイヤ (フラグ未提供) は false にフォールバックし、テンプレート導線を
  /// 出さない。存在ベースの静的フラグなので per-user 評価は不要。
  final bool composeTemplatesEnabled;

  final List<String> adminRoleIds;
  final String? infoBotAcct;

  // 劇中ワード辞書のローカルキャッシュ (#687)。`/word/all` を一括取得して TTL
  // 内はローカル絞り込みで即応し、TTL 経過後は stale-while-revalidate で古い
  // 辞書のまま即応しつつ裏で digest (If-None-Match) 再検証する。サービスは
  // アカウントに紐づき寿命が安定なので、投稿セッションを跨いでキャッシュが効く。
  List<WordSuggestion>? _wordDictionary;
  String? _wordDictionaryDigest;
  DateTime? _wordDictionaryFetchedAt;
  Future<void>? _wordDictionaryInflight;

  /// 辞書は「意外と頻繁に」更新されるため TTL は短め。失効しても再取得は
  /// 条件付き GET (304 なら本文なし) で軽い。
  static const _wordDictionaryTtl = Duration(minutes: 5);

  MulukhiyaService._({
    required Dio dio,
    required this.baseUrl,
    required this.controllerType,
    required this.version,
    this.maxPostLength,
    this.postLabel,
    this.themeColorHex,
    this.defaultHashtag,
    this.reblogLabel,
    this.annictEnabled = false,
    this.annictLinked = true,
    this.annictReviewEnabled = false,
    this.mediaCatalogEnabled = false,
    this.announcementPushEnabled = false,
    this.wordSuggestEnabled = false,
    this.nowplayingResolverEnabled = false,
    this.nowplayingUrlResolverEnabled = false,
    this.spotifyEnabled = false,
    this.spotifyLinked = false,
    this.composeTemplatesEnabled = false,
    this.foundedAt,
    this.preopenedAt,
    this.adminRoleIds = const [],
    this.infoBotAcct,
  }) : _dio = dio;

  Options _bearerOptions(String token) =>
      Options(headers: {'Authorization': 'Bearer $token'});

  /// Mulukhiya の `Ginseng::AuthError` は HTTP 403 を返す（401 ではない）。
  /// 認証失効を機能未提供と同列に握りつぶして graceful fallback したい
  /// 各 endpoint から共通で使う。
  bool _isAuthError(DioException e) => e.response?.statusCode == 403;

  /// Detect mulukhiya by requesting GET /mulukhiya/api/about.
  /// Returns [MulukhiyaService] if present, null otherwise.
  ///
  /// [token] を渡すと /about を当該アカウントの bearer 認証付きで叩く。
  /// `features.annict_linked` 等の **per-user 動的フラグ** はリクエストの
  /// トークンが指すアカウントで評価されるため (mulukhiya DynamicFeatures、
  /// #611)、未指定だとサーバーの default_token で評価され当該ユーザーの
  /// 連携状態にならない。token は新規ログイン / セッション復元時に手元にある。
  static Future<MulukhiyaService?> detect(
    Dio dio,
    String domain, {
    String? token,
  }) async {
    try {
      final response = await dio.get(
        'https://$domain/mulukhiya/api/about',
        options: Options(
          responseType: ResponseType.json,
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
          headers: token != null ? {'Authorization': 'Bearer $token'} : null,
        ),
      );
      if (response.statusCode != 200) return null;
      final data = response.data is Map<String, dynamic>
          ? response.data as Map<String, dynamic>
          : null;
      if (data == null) return null;

      final package = data['package'] as Map<String, dynamic>?;
      final config = data['config'] as Map<String, dynamic>?;
      if (package == null || config == null) return null;

      final status = config['status'] as Map<String, dynamic>?;
      final theme = config['theme'] as Map<String, dynamic>?;
      final features = config['features'] as Map<String, dynamic>?;

      final adminRoleIds =
          (config['admin_role_ids'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [];

      final infoBot = config['info_bot'] as Map<String, dynamic>?;

      return MulukhiyaService._(
        dio: dio,
        baseUrl: 'https://$domain/mulukhiya/api',
        controllerType: config['controller'] as String? ?? 'mastodon',
        version: package['version'] as String? ?? '0.0.0',
        maxPostLength: status?['max_length'] as int?,
        postLabel: status?['label'] as String?,
        themeColorHex: theme?['color'] as String?,
        defaultHashtag: _parseDefaultHashtag(status?['default_hashtag']),
        reblogLabel: status?['reblog_label'] as String?,
        annictEnabled: features?['annict'] == true,
        // 欠落時は連携状態を判別できないため true にフォールバック (#611)。
        annictLinked: features?['annict_linked'] != false,
        annictReviewEnabled: features?['annict_review'] == true,
        mediaCatalogEnabled: features?['media_catalog'] == true,
        announcementPushEnabled: features?['announcement_push'] == true,
        wordSuggestEnabled: features?['word_suggest'] == true,
        nowplayingResolverEnabled: features?['nowplaying_resolver'] == true,
        nowplayingUrlResolverEnabled:
            features?['nowplaying_url_resolver'] == true,
        spotifyEnabled: features?['spotify_enabled'] == true,
        // 欠落・未連携時はナウプレ挿入導線を出さない (#570)。連携導線は設定画面側。
        spotifyLinked: features?['spotify_linked'] == true,
        composeTemplatesEnabled: features?['compose_templates'] == true,
        foundedAt: _parseIsoDate(config['founded_at']),
        preopenedAt: _parseIsoDate(config['preopened_at']),
        adminRoleIds: adminRoleIds,
        infoBotAcct: infoBot?['acct'] as String?,
      );
    } catch (_) {
      // Not found or connection error — mulukhiya not present
    }
    return null;
  }

  /// GET /mulukhiya/api/health
  Future<Map<String, dynamic>> checkHealth() async {
    final response = await _dio.get('$baseUrl/health');
    return response.data as Map<String, dynamic>;
  }

  Future<MulukhiyaAbout> getAbout() async {
    final response = await _dio.get('$baseUrl/about');
    final data = response.data as Map<String, dynamic>;
    final package = data['package'] as Map<String, dynamic>;
    return MulukhiyaAbout(
      version: package['version'] as String,
      controllerType:
          (data['config'] as Map<String, dynamic>)['controller'] as String,
      packageUrl: package['url'] as String?,
    );
  }

  /// Fetch the program list for tagset selection.
  ///
  /// **並び順はサーバーが決めたものをそのまま保つ** (#965 / モロヘイヤ #4540)。
  /// モロヘイヤ 5.32.0 以降、`/program` は放送順 (`next_on` 昇順 → `start_time`
  /// 昇順、`next_on` を持たない「毎日」枠は末尾) で返す。エントリのキーは
  /// SHA256 の先頭 12 桁固定で JS の配列インデックスにならないため、JSON を
  /// 通しても挿入順が保たれる (Dart では `jsonDecode` が `LinkedHashMap` を返す)。
  ///
  /// ⚠ **ここで並べ替えたり `LinkedHashMap` 以外へ詰め替えたりしないこと。**
  /// 戻り値の `<String, MulukhiyaProgram>{}` リテラルは `LinkedHashMap` で、
  /// 挿入順のまま UI が描画する。`SplayTreeMap` に変える・`sort` を足す・
  /// フィルタを別のコレクション経由にする、といった変更で黙って壊れる
  /// (`mulukhiya_program_order_test.dart` が固定している)。
  Future<Map<String, MulukhiyaProgram>> getProgram() async {
    final response = await _dio.get('$baseUrl/program');
    final data = response.data as Map<String, dynamic>;
    final programs = <String, MulukhiyaProgram>{};
    for (final entry in data.entries) {
      final v = entry.value;
      if (v is! Map<String, dynamic>) continue;
      if (v['enable'] != true && v['enable'] != 1) continue;
      programs[entry.key] = MulukhiyaProgram(
        name: entry.key,
        series: v['series'] as String?,
        episode: v['episode']?.toString(),
        episodeSuffix: v['episode_suffix'] as String? ?? '話',
        subtitle: v['subtitle'] as String?,
        air: v['air'] == true || v['air'] == 1,
        livecure: v['livecure'] == true || v['livecure'] == 1,
        minutes: v['minutes'] as int?,
        extraTags:
            (v['extra_tags'] as List?)?.map((e) => e.toString()).toList() ?? [],
        annictWorkId: v['annict_work_id'] as int?,
        annictEpisodeId: v['annict_episode_id'] as int?,
        startTime: parseProgramStartTime(v['start_time']),
        nextOn: parseProgramNextOn(v['next_on']),
      );
    }
    return programs;
  }

  /// Trigger program data update on the server.
  Future<void> updateProgram() async {
    await _dio.post('$baseUrl/program/update');
  }

  /// Get the Annict OAuth authorization URL from the server.
  /// The client_id is server-side config, so capsicum cannot build this URL.
  Future<String> getAnnictOAuthUri() async {
    final response = await _dio.get('$baseUrl/annict/oauth_uri');
    final data = response.data as Map<String, dynamic>;
    return data['oauth_uri'] as String;
  }

  /// Exchange an Annict OAuth authorization code for an access token.
  /// The token is stored server-side in the user's mulukhiya config.
  /// [snsToken] is the SNS account token for authentication.
  /// [annictCode] is the authorization code from Annict OAuth.
  Future<void> authenticateAnnict({
    required String snsToken,
    required String annictCode,
  }) async {
    await _dio.post(
      '$baseUrl/annict/auth',
      data: {'token': snsToken, 'code': annictCode},
      options: _bearerOptions(snsToken),
    );
  }

  /// Spotify user-level OAuth の認可 URL をサーバーから取得する (#570)。
  /// client_id / redirect_uri はサーバー側 config なので capsicum は組み立てない。
  Future<String> getSpotifyOAuthUri() async {
    final response = await _dio.get('$baseUrl/spotify/oauth_uri');
    final data = response.data as Map<String, dynamic>;
    return data['oauth_uri'] as String;
  }

  /// Spotify OAuth の認可コードを access/refresh トークンに交換する (#570)。
  /// トークンはモロヘイヤ側で当該ユーザーに紐付けて暗号化保管される。
  /// ユーザー特定は Bearer ([snsToken]) で行うため body は `code` のみ
  /// (mulukhiya SpotifyAuthContract に準拠)。
  Future<void> authenticateSpotify({
    required String snsToken,
    required String code,
  }) async {
    await _dio.post(
      '$baseUrl/spotify/auth',
      data: {'code': code},
      options: _bearerOptions(snsToken),
    );
  }

  /// 現在 Spotify で再生中のトラックの共有 URL を取得する (#570)。
  ///
  /// 再生中なら `https`/`http` の URL、未再生 / 広告 / プライベートセッションは
  /// null。access_token の期限切れはモロヘイヤ側が refresh で隠蔽するが、
  /// refresh も失効 / 未連携のときモロヘイヤは 403 を返す。これは「無音」と
  /// 区別して再連携導線を出せるよう [MulukhiyaSpotifyAuthException] を投げる。
  Future<Uri?> getSpotifyCurrentlyPlaying(String snsToken) async {
    try {
      final response = await _dio.get(
        '$baseUrl/spotify/currently_playing',
        options: _bearerOptions(snsToken),
      );
      final data = response.data;
      final url = data is Map<String, dynamic> ? data['url'] : null;
      if (url is! String || url.isEmpty) return null;
      final uri = Uri.tryParse(url);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return null;
      }
      return uri;
    } on DioException catch (e) {
      if (_isAuthError(e)) throw const MulukhiyaSpotifyAuthException();
      rethrow;
    }
  }

  /// Spotify 連携を解除する (#570)。モロヘイヤ側の保管トークンを破棄する。
  Future<void> unlinkSpotify(String snsToken) async {
    await _dio.delete(
      '$baseUrl/spotify/auth',
      options: _bearerOptions(snsToken),
    );
  }

  /// Search Annict works by keyword.
  /// Returns an empty list if Annict is not enabled or the user is not
  /// authenticated with Annict.
  Future<List<AnnictWork>> searchWorks({String? keyword}) async {
    final response = await _dio.get(
      '$baseUrl/program/works',
      queryParameters: {'q': ?keyword},
    );
    final data = response.data;
    if (data is! List) return [];
    return data
        .whereType<Map<String, dynamic>>()
        .where((m) {
          return m['annictId'] is int && m['title'] is String;
        })
        .map((m) {
          return AnnictWork(
            annictId: m['annictId'] as int,
            title: m['title'] as String,
            seasonYear: m['seasonYear'] as int?,
            officialSiteUrl: m['officialSiteUrl'] as String?,
            hashtag: m['hashtag'] as String?,
            commandToot: m['command_toot'] as String?,
          );
        })
        .toList();
  }

  /// Post a viewing record (感想) to Annict via mulukhiya.
  ///
  /// モロヘイヤ #4227 で実装された `POST /api/annict/record` を呼ぶ (#298)。
  /// Annict OAuth トークンはモロヘイヤ側で保持しているため、ここでは SNS
  /// 側の access_token を Bearer で渡すだけでよい。レーティングと感想本文は
  /// 任意 (片方だけ送ることも、両方空で「視聴済み」だけ立てることも可)。
  Future<void> postAnnictRecord({
    required String snsToken,
    required int episodeId,
    String? comment,
    AnnictRatingState? ratingState,
  }) async {
    await _dio.post(
      '$baseUrl/annict/record',
      data: {
        'episode_id': episodeId,
        if (comment != null && comment.isNotEmpty) 'comment': comment,
        if (ratingState != null) 'rating_state': ratingState.apiValue,
      },
      options: _bearerOptions(snsToken),
    );
  }

  /// Post a work-level review (作品全体感想) to Annict via mulukhiya.
  ///
  /// モロヘイヤ #4342 で実装された `POST /api/annict/review` を呼ぶ (#592)。
  /// 劇場版のように episode に分かれていない作品は record の投稿先がなく、
  /// review でしか感想を残せないため record (単話) の作品単位ペアとして使う。
  /// [body] (感想本文) は必須。レーティングは総合 + 4 軸 (映像 / 音楽 / 物語 /
  /// キャラクター) いずれも任意。record と同じく SNS 側の access_token を
  /// Bearer で渡すだけでよい (Annict トークンはモロヘイヤ側が保持)。
  Future<void> postAnnictReview({
    required String snsToken,
    required int workId,
    required String body,
    AnnictRatingState? ratingOverall,
    AnnictRatingState? ratingAnimation,
    AnnictRatingState? ratingMusic,
    AnnictRatingState? ratingStory,
    AnnictRatingState? ratingCharacter,
  }) async {
    await _dio.post(
      '$baseUrl/annict/review',
      data: {
        'work_id': workId,
        'body': body,
        if (ratingOverall != null)
          'rating_overall_state': ratingOverall.apiValue,
        if (ratingAnimation != null)
          'rating_animation_state': ratingAnimation.apiValue,
        if (ratingMusic != null) 'rating_music_state': ratingMusic.apiValue,
        if (ratingStory != null) 'rating_story_state': ratingStory.apiValue,
        if (ratingCharacter != null)
          'rating_character_state': ratingCharacter.apiValue,
      },
      options: _bearerOptions(snsToken),
    );
  }

  /// Fetch episodes for a given Annict work ID.
  Future<List<AnnictEpisode>> getEpisodes(int workId) async {
    final response = await _dio.get('$baseUrl/program/works/$workId/episodes');
    final data = response.data;
    if (data is! List) return [];
    return data
        .whereType<Map<String, dynamic>>()
        .where((m) {
          return m['annictId'] is int;
        })
        .map((m) {
          return AnnictEpisode(
            annictId: m['annictId'] as int,
            numberText: m['numberText'] as String?,
            title: m['title'] as String?,
            hashtag: m['hashtag'] as String?,
            url: m['url'] as String?,
            commandToot: m['command_toot'] as String?,
          );
        })
        .toList();
  }

  /// Fetch server custom links from /links.json.
  /// Supports both grouped (Mastodon) and flat (Misskey) formats.
  Future<List<ServerLinkGroup>> getLinks(String host) async {
    try {
      final response = await _dio.get('https://$host/links.json');
      final data = response.data;
      if (data is! List) return [];

      final groups = <ServerLinkGroup>[];
      for (final item in data) {
        if (item is! Map<String, dynamic>) continue;
        if (item.containsKey('links')) {
          // Grouped format (Mastodon)
          final rawLinks = item['links'] as List?;
          if (rawLinks == null) continue;
          final links = _parseLinks(rawLinks);
          if (links.isNotEmpty) {
            groups.add(
              ServerLinkGroup(title: item['body'] as String?, links: links),
            );
          }
        } else {
          // Flat format (Misskey) — collect into a single group
          final link = _parseLink(item);
          if (link != null) {
            groups.add(ServerLinkGroup(links: [link]));
          }
        }
      }
      return groups;
    } catch (_) {
      return [];
    }
  }

  List<ServerLink> _parseLinks(List items) {
    return items
        .whereType<Map<String, dynamic>>()
        .map(_parseLink)
        .whereType<ServerLink>()
        .toList();
  }

  ServerLink? _parseLink(Map<String, dynamic> m) {
    final href = m['href'] as String?;
    if (href == null) return null;
    return ServerLink(
      href: href,
      body: m['body'] as String? ?? href,
      icon: m['icon'] as String?,
    );
  }

  /// Restore avatar decoration to the saved state before tagset was applied.
  /// Requires the user's SNS access token for authentication.
  /// Returns true if restoration succeeded, false if not applicable (e.g. no
  /// saved state or decoration feature not available).
  Future<bool> restoreDecoration(String accessToken) async {
    try {
      await _dio.post(
        '$baseUrl/decoration/restore',
        options: _bearerOptions(accessToken),
      );
      return true;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404 || _isAuthError(e)) {
        return false;
      }
      rethrow;
    }
  }

  /// Fetch favorite tags (tags found in user profiles) with user counts.
  /// Requires `/{controller}/data/favorite_tags` to be enabled.
  /// Returns empty list if the feature is disabled (404).
  Future<List<FavoriteTag>> getFavoriteTags() async {
    try {
      final response = await _dio.get('$baseUrl/tagging/favorites');
      final data = response.data;
      if (data is Map<String, dynamic>) {
        return data.entries.map((e) {
          final value = e.value as Map<String, dynamic>;
          return FavoriteTag(
            name: e.key,
            url: value['url'] as String?,
            count: value['count'] as int? ?? 0,
          );
        }).toList();
      }
      return [];
    } on DioException catch (e) {
      if (e.response?.statusCode == 404 || _isAuthError(e)) return [];
      rethrow;
    }
  }

  /// 読み付き単語サジェスト (劇中ワード補完) を引く (#4397 / capsicum#614)。
  /// GET /mulukhiya/api/word/suggest
  ///
  /// [q] にユーザー入力 (主にひらがな読み) を渡す。ひらがな↔カタカナ・全半角の
  /// 揺れはモロヘイヤ側で吸収されるため素の読みを渡せばよい。並び順もサーバー側で
  /// 確定済み。辞書未設定 (`features.word_suggest` が false) のサーバーは 404 を
  /// 返すため、その場合は空リストにフォールバックする。
  Future<List<WordSuggestion>> suggestWords({
    required String q,
    int? limit,
  }) async {
    try {
      final response = await _dio.get(
        '$baseUrl/word/suggest',
        queryParameters: {'q': q, 'limit': ?limit},
      );
      final candidates = response.data is Map<String, dynamic>
          ? (response.data as Map<String, dynamic>)['candidates']
          : null;
      if (candidates is! List) return [];
      return candidates
          .whereType<Map<String, dynamic>>()
          .where((m) => m['surface'] is String && m['reading'] is String)
          .map((m) {
            return WordSuggestion(
              surface: m['surface'] as String,
              reading: m['reading'] as String,
              category: m['category'] as String?,
            );
          })
          .toList();
    } on DioException catch (e) {
      // 404 = 辞書未設定。403 (_isAuthError) = サジェストを認証必須にしている
      // サーバーで未ログイン相当。どちらも「補完が使えない」だけなので空に倒し、
      // 投稿フォーム本体は通常どおり動かす。5xx/network は rethrow して上位へ。
      if (e.response?.statusCode == 404 || _isAuthError(e)) return [];
      rethrow;
    }
  }

  /// 劇中ワードサジェストを **一括取得 + ローカル絞り込み** で引く (#687)。
  ///
  /// 打鍵ごとにサーバー `word/suggest` を叩く [suggestWords] の最適化版。辞書全体
  /// (`/word/all`) を一度取得してローカルで絞り込むため、2 打鍵目以降は往復ゼロで
  /// 即応し、実況の打鍵テンポを損なわない。呼び出し規約 (q / limit / 戻り値) は
  /// [suggestWords] と同一で、そのまま差し替えられる。
  ///
  /// フォールバック方針 (実用版正規化 + サーバー救済):
  /// - `/word/all` が使えない (未対応の旧モロヘイヤ = 404 / cold-cache / エラー)
  ///   ときは、都度クエリの [suggestWords] にそのまま倒す (従来挙動)。
  /// - ローカル 0 件でも、クエリが実用版正規化の穴 (NFKC 相当が要る半角カナ等) を
  ///   含むときはサーバー正規化に委ねる。純粋なかな/漢字なら 0 件は確定 (同じ
  ///   辞書を突き合わせる以上サーバーも 0) なので往復しない。
  Future<List<WordSuggestion>> suggestWordsLocal({
    required String q,
    int? limit,
  }) async {
    if (_wordDictionary == null) {
      // 初回のみ取得を待つ (以降は即応)。prewarmWordDictionary で事前充填すれば
      // この待ちも消える。
      await _ensureWordDictionary();
    } else if (_wordDictionaryStale) {
      // stale-while-revalidate: 古い辞書で即応しつつ裏で再検証する。
      unawaited(_ensureWordDictionary());
    }
    final dictionary = _wordDictionary;
    if (dictionary == null) {
      // 一括取得が使えない。従来の都度クエリに倒す。
      return suggestWords(q: q, limit: limit);
    }
    final local = filterWordSuggestions(dictionary, q, limit: limit);
    if (local.isNotEmpty) return local;
    if (queryMayNeedServerNormalization(q)) {
      return suggestWords(q: q, limit: limit);
    }
    return const [];
  }

  /// 劇中ワード辞書を事前に充填する (#687)。投稿画面や絵文字ピッカーの劇中ワード
  /// タブが有効になった時点で呼ぶと、最初の打鍵で辞書取得を待たずに済む。best-effort
  /// で、失敗しても [suggestWordsLocal] が都度クエリに倒すため投稿フローは止まらない。
  Future<void> prewarmWordDictionary() => _ensureWordDictionary();

  bool get _wordDictionaryStale {
    final at = _wordDictionaryFetchedAt;
    return at == null || DateTime.now().difference(at) >= _wordDictionaryTtl;
  }

  /// 辞書キャッシュが空 / 失効していれば `/word/all` で取得・再検証する。
  /// 同時多重取得は in-flight future を共有して 1 本に束ねる。
  Future<void> _ensureWordDictionary() {
    final inflight = _wordDictionaryInflight;
    if (inflight != null) return inflight;
    if (_wordDictionary != null && !_wordDictionaryStale) {
      return Future.value();
    }
    final future = _fetchWordDictionary();
    _wordDictionaryInflight = future;
    return future.whenComplete(() {
      if (identical(_wordDictionaryInflight, future)) {
        _wordDictionaryInflight = null;
      }
    });
  }

  /// GET /mulukhiya/api/word/all (#687 / mulukhiya#4430)。digest を保持している
  /// ときは If-None-Match を付け、304 なら本文なしで鮮度だけ更新する。取得失敗は
  /// best-effort で握りつぶし、キャッシュを従来経路に委ねる。
  Future<void> _fetchWordDictionary() async {
    try {
      final digest = _wordDictionaryDigest;
      final response = await _dio.get(
        '$baseUrl/word/all',
        options: Options(
          headers: {if (digest != null) 'If-None-Match': '"$digest"'},
          // 304 (未変更) を例外にしない。
          validateStatus: (s) =>
              s != null && (s == 304 || (s >= 200 && s < 300)),
        ),
      );
      if (response.statusCode == 304) {
        _wordDictionaryFetchedAt = DateTime.now();
        return;
      }
      final data = response.data;
      if (data is! Map<String, dynamic>) return;
      final words = data['words'];
      if (words is! List) return;
      _wordDictionary = words
          .whereType<Map<String, dynamic>>()
          .where((m) => m['surface'] is String && m['reading'] is String)
          .map(
            (m) => WordSuggestion(
              surface: m['surface'] as String,
              reading: m['reading'] as String,
              // category が想定外の型 (数値等) でもエントリを落とさず null に倒す
              // (#821)。`as String?` だと非 String 非 null で TypeError になり、
              // .toList() が辞書全体の parse を巻き添えに飛ばしていた。
              category: m['category'] is String
                  ? m['category'] as String
                  : null,
            ),
          )
          .toList();
      _wordDictionaryDigest = data['digest'] as String?;
      _wordDictionaryFetchedAt = DateTime.now();
    } catch (_) {
      // DioException (404 旧モロヘイヤに /word/all 無し / 403 認証必須 / 5xx /
      // network) に加え、想定外レスポンスの TypeError 等も best-effort で握りつぶす
      // (#821)。キャッシュを空のままにし、suggestWordsLocal 側の都度クエリ
      // fallback に委ねる。rethrow すると初回 await が投げ、stale-revalidate の
      // unawaited(_ensureWordDictionary()) 経路は未捕捉 async エラー (Sentry
      // ノイズ) になる。
      return;
    }
  }

  /// POST /mulukhiya/api/nowplaying/resolve (#669 / mulukhiya #4382)
  ///
  /// URL を持たないナウプレ源 (Apple Music / Linux MPRIS / Windows SMTC) の
  /// 構造化メタデータを渡し、Spotify / iTunes 検索で **共有可能な URL** を解決する
  /// enrich プロキシ。[nowplayingResolverEnabled] が true のサーバーでのみ呼ぶ。
  ///
  /// あくまで **任意の上積み**。ヒットすれば URL を返し、ヒットなし (200 +
  /// `{url: null}`) / 認証失効 (403) / 未提供 (404) / バリデーション (422) /
  /// 5xx・network はすべて null に倒す。呼び出し側は URL なしのクライアント整形
  /// ([formatNowPlayingFallback]) にフォールバックし、投稿フローを止めない。
  ///
  /// 整形はクライアント側で行うため、本 API はテキスト整形を含まず URL のみ使う
  /// （design: nowplaying-design.md §責務分担）。
  /// [prefer] は URL 優先プロバイダ (#681、`apple_music` / `spotify`)。モロヘイヤ
  /// 側のプロバイダ優先3段連鎖 (`prefer` > `source_app_name` > サーバー既定
  /// `apple_music`) の最上位ヒントとして毎回送る。null なら省略しサーバー既定に倒す。
  Future<Uri?> resolveNowPlaying({
    required String accessToken,
    required String title,
    String? artist,
    String? album,
    String? sourceAppName,
    String? prefer,
  }) async {
    try {
      final response = await _dio.post(
        '$baseUrl/nowplaying/resolve',
        data: {
          'title': title,
          'artist': ?artist,
          'album': ?album,
          'source_app_name': ?sourceAppName,
          'prefer': ?prefer,
        },
        options: _bearerOptions(accessToken),
      );
      final url = response.data is Map<String, dynamic>
          ? (response.data as Map<String, dynamic>)['url']
          : null;
      if (url is! String || url.isEmpty) return null;
      final uri = Uri.tryParse(url);
      // 投稿本文に挿入されるため、http/https 以外（javascript: / data: 等）は
      // 弾く。モロヘイヤは信頼境界内だが、共有 URL 判定（composeSharedNowPlaying）
      // と同じスキーム規律に揃える。
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return null;
      }
      return uri;
    } on DioException {
      // enrich は任意の上積みなので、未提供・認証失効・サーバ不調・network いずれも
      // null に倒して URL なし整形へフォールバックする（UX を止めない）。
      return null;
    }
  }

  /// POST /mulukhiya/api/nowplaying/resolve-url (#729 / mulukhiya #4415)
  ///
  /// 共有(Share)経路の **URL から** title/artist/album を解決する逆 enrich。
  /// [resolveNowPlaying]（メタ→URL, #669）の逆方向で、URL しか持たない共有
  /// ナウプレ投稿を in-app と同じ [formatNowPlayingFallback] に通せるようにする。
  /// [nowplayingUrlResolverEnabled] が true のサーバーでのみ呼ぶ。
  ///
  /// 解決できれば [NowPlayingInfo]（url は正規化済み）を返す。未対応 host・
  /// メタ無し (200 + `{url: null}`)・認証失効 (403)・未提供 (404)・バリデーション
  /// (422)・5xx・network はすべて null に倒し、呼び出し側は従来の共有整形
  /// （[composeSharedNowPlaying]、モロヘイヤ post-time enrich 任せ）へフォールバック
  /// する。
  Future<NowPlayingInfo?> resolveNowPlayingByUrl({
    required String accessToken,
    required String url,
  }) async {
    try {
      final response = await _dio.post(
        '$baseUrl/nowplaying/resolve-url',
        data: {'url': url},
        options: _bearerOptions(accessToken),
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) return null;
      final resolvedUrl = data['url'];
      if (resolvedUrl is! String || resolvedUrl.isEmpty) return null;
      final uri = Uri.tryParse(resolvedUrl);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return null;
      }
      final normalized = data['normalized'];
      final meta = normalized is Map<String, dynamic>
          ? normalized
          : const <String, dynamic>{};
      return NowPlayingInfo(
        sourceAppName: _nowPlayingProviderLabel(data['provider']),
        title: meta['title'] as String?,
        artist: meta['artist'] as String?,
        album: meta['album'] as String?,
        url: uri,
      );
    } on DioException {
      return null;
    }
  }

  /// resolve-url の `provider`（`spotify` / `apple_music`）を表示用ラベルへ。
  /// [NowPlayingInfo.sourceAppName] は URL を持つ本経路では整形に使われない
  /// （[formatNowPlayingFallback] は labeled か url があれば source を出さない）が、
  /// モデルが非 null を要求するため埋める。
  static String _nowPlayingProviderLabel(Object? provider) =>
      switch (provider) {
        'spotify' => 'Spotify',
        'apple_music' => 'Apple Music',
        _ => '',
      };

  /// Update tags on a scheduled status (Mastodon only).
  /// PUT /mulukhiya/api/scheduled_status/:id/tags
  /// Returns the new scheduled status ID (the server recreates the post).
  Future<String> updateScheduledStatusTags({
    required String accessToken,
    required String id,
    required List<String> tags,
  }) async {
    final response = await _dio.put(
      '$baseUrl/scheduled_status/$id/tags',
      data: {'tags': tags},
      options: _bearerOptions(accessToken),
    );
    final data = response.data as Map<String, dynamic>;
    return data['id'] as String;
  }

  /// DELETE /mulukhiya/api/status/nowplaying
  /// Removes NowPlaying information from a post and reposts it.
  Future<void> deleteNowPlaying({
    required String accessToken,
    required String id,
  }) async {
    await _dio.delete(
      '$baseUrl/status/nowplaying',
      data: {'id': id},
      options: _bearerOptions(accessToken),
    );
  }

  /// POST /mulukhiya/api/status/tags
  /// Deletes the post and reposts it with the given tags.
  ///
  /// 再投稿された投稿の生 JSON を返す（**SNS 本体の投稿 API のレスポンスそのまま**。
  /// Mastodon はトップレベルが status、Misskey は `createdNote` 包み）。呼び出し側は
  /// [MulukhiyaRepostSupport.parseRepostedPost] で [Post] へ変換して TL に挿す (#909)。
  /// 形が想定外なら null を返す。
  Future<Map<String, dynamic>?> updateStatusTags({
    required String accessToken,
    required String id,
    required List<String> tags,
  }) async {
    final response = await _dio.post(
      '$baseUrl/status/tags',
      data: {'id': id, 'tags': tags},
      options: _bearerOptions(accessToken),
    );
    final data = response.data;
    return data is Map<String, dynamic> ? data : null;
  }

  /// 投稿テンプレート一覧を取得する (#767)。
  /// GET /mulukhiya/api/compose/templates
  Future<List<ComposeTemplate>> getComposeTemplates({
    required String accessToken,
  }) async {
    final response = await _dio.get(
      '$baseUrl/compose/templates',
      options: _bearerOptions(accessToken),
    );
    return _parseTemplates(response.data);
  }

  /// 投稿テンプレートを新規作成する (#767)。作成後の**全件**を返す。
  /// POST /mulukhiya/api/compose/templates
  Future<List<ComposeTemplate>> createComposeTemplate({
    required String accessToken,
    required String name,
    required String body,
    String? cw,
  }) async {
    final response = await _dio.post(
      '$baseUrl/compose/templates',
      data: {'name': name, 'body': body, 'cw': ?cw},
      options: _bearerOptions(accessToken),
    );
    return _parseTemplates(response.data);
  }

  /// 既存テンプレートを更新する (#767)。更新後の**全件**を返す。
  /// PUT /mulukhiya/api/compose/templates/:id
  Future<List<ComposeTemplate>> updateComposeTemplate({
    required String accessToken,
    required String id,
    required String name,
    required String body,
    String? cw,
  }) async {
    final response = await _dio.put(
      '$baseUrl/compose/templates/$id',
      data: {'name': name, 'body': body, 'cw': ?cw},
      options: _bearerOptions(accessToken),
    );
    return _parseTemplates(response.data);
  }

  /// テンプレートを削除する (#767)。削除後の**全件**を返す。
  /// DELETE /mulukhiya/api/compose/templates/:id
  Future<List<ComposeTemplate>> deleteComposeTemplate({
    required String accessToken,
    required String id,
  }) async {
    final response = await _dio.delete(
      '$baseUrl/compose/templates/$id',
      options: _bearerOptions(accessToken),
    );
    return _parseTemplates(response.data);
  }

  /// compose/templates 系レスポンスの `templates` 配列を model に変換する。
  List<ComposeTemplate> _parseTemplates(dynamic data) {
    final map = data is Map<String, dynamic> ? data : const {};
    final list = map['templates'] as List? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(ComposeTemplate.fromJson)
        .toList();
  }

  /// Fetch emoji palettes from the server (Misskey only).
  /// Requires the user's SNS access token for authentication.
  /// Returns structured palette data with main/reaction assignments.
  Future<EmojiPalettesResult> getEmojiPalettes({
    required String accessToken,
  }) async {
    final response = await _dio.get(
      '$baseUrl/emoji/palettes',
      options: _bearerOptions(accessToken),
    );
    final data = response.data as Map<String, dynamic>;
    final palettes = data['palettes'] as List? ?? [];
    final reactionId = data['palette_for_reaction'] as String?;
    final mainId = data['palette_for_main'] as String?;

    final parsed = <EmojiPaletteEntry>[];
    for (final p in palettes) {
      final palette = p as Map<String, dynamic>;
      final emojis = (palette['emojis'] as List? ?? [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList();
      parsed.add(
        EmojiPaletteEntry(
          id: palette['id'] as String? ?? '',
          name: palette['name'] as String? ?? '',
          emojis: emojis,
        ),
      );
    }

    return EmojiPalettesResult(
      palettes: parsed,
      paletteForReaction: reactionId,
      paletteForMain: mainId,
    );
  }

  /// Fetch media catalog from /mulukhiya/api/media.
  /// Returns empty result if the feature is disabled (404).
  Future<MediaCatalogResult> getMediaCatalog({
    int page = 1,
    String? query,
    bool personOnly = false,
  }) async {
    try {
      final response = await _dio.get(
        '$baseUrl/media',
        queryParameters: {
          'page': page,
          if (query != null && query.isNotEmpty) 'q': query,
          if (personOnly) 'only_person': 1,
        },
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        return const MediaCatalogResult(items: [], hasNext: false);
      }
      final rawItems = data['items'] as List? ?? [];
      final hasNext = data['has_next'] as bool? ?? false;
      final items = rawItems.map((e) {
        final m = e as Map<String, dynamic>;
        final account = m['account'] as Map<String, dynamic>?;
        final status = m['status'] as Map<String, dynamic>?;
        return MediaCatalogItem(
          id: m['id']?.toString() ?? '',
          url: m['url'] as String? ?? '',
          thumbnailUrl: m['thumbnail_url'] as String?,
          createdAt: m['created_at'] as String?,
          fileName: m['file_name'] as String?,
          fileSizeStr: m['file_size_str'] as String?,
          type: m['type'] as String?,
          mediatype: m['mediatype'] as String?,
          pixelSize: m['pixel_size'] as String?,
          duration: (m['duration'] as num?)?.toDouble(),
          accountUsername: account?['username'] as String?,
          accountDisplayName: account?['display_name'] as String?,
          statusBody: status?['body'] as String?,
          statusPublicUrl: status?['public_url'] as String?,
        );
      }).toList();
      return MediaCatalogResult(items: items, hasNext: hasNext);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404 || _isAuthError(e)) {
        return const MediaCatalogResult(items: [], hasNext: false);
      }
      rethrow;
    }
  }

  /// Fetch default hashtags from /mulukhiya/api/about.
  /// The about endpoint is public (no auth required).
  Future<List<String>> getDefaultHashtags() async {
    try {
      final response = await _dio.get('$baseUrl/about');
      final data = response.data as Map<String, dynamic>?;
      if (data == null) return [];
      final config = data['config'] as Map<String, dynamic>?;
      if (config == null) return [];
      final status = config['status'] as Map<String, dynamic>?;
      if (status == null) return [];
      final defaultHashtag = status['default_hashtag'];
      if (defaultHashtag is String) {
        return [defaultHashtag.replaceFirst('#', '')];
      }
      if (defaultHashtag is List) {
        return defaultHashtag
            .map((e) => e.toString().replaceFirst('#', ''))
            .toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// Misskey Web Push サブスクリプションをモロヘイヤ経由で登録する。
  /// POST /mulukhiya/api/sw/register
  ///
  /// Misskey 本家は GHSA-7pxq-6xx9-xpgm 対策で `/api/sw/register` を
  /// `secure: true` で制限しており、MiAuth / OAuth トークンからは叩けない。
  /// モロヘイヤ導入済みサーバーでのみ使える代替経路。
  ///
  /// [accessToken] は `write:account` スコープを持つ SNS アクセストークン。
  Future<Map<String, dynamic>> subscribePushViaProxy({
    required String accessToken,
    required String endpoint,
    required String publickey,
    required String auth,
  }) async {
    final response = await _dio.post(
      '$baseUrl/sw/register',
      data: {
        'endpoint': endpoint,
        'publickey': publickey,
        'auth': auth,
        'sendReadMessage': false,
      },
      options: _bearerOptions(accessToken),
    );
    return response.data as Map<String, dynamic>;
  }

  /// Misskey Web Push サブスクリプションをモロヘイヤ経由で解除する。
  /// POST /mulukhiya/api/sw/unregister
  Future<Map<String, dynamic>> unsubscribePushViaProxy({
    required String accessToken,
    required String endpoint,
    required String publickey,
    required String auth,
  }) async {
    final response = await _dio.post(
      '$baseUrl/sw/unregister',
      data: {
        'endpoint': endpoint,
        'publickey': publickey,
        'auth': auth,
        'sendReadMessage': false,
      },
      options: _bearerOptions(accessToken),
    );
    return response.data as Map<String, dynamic>;
  }

  /// 複数 acct の isCat フラグを一括取得する。
  /// モロヘイヤの `POST /account/is_cat` を呼び出し、ActivityPub actor から
  /// isCat を取得する（Redis キャッシュ付き）。
  ///
  /// 戻り値は3値: `true`（猫）/ `false`（猫でない）/ `null`（取得失敗・不明）。
  /// 通信エラー時は `null` を返す（空 Map と区別するため）。
  Future<Map<String, bool?>?> fetchIsCat({
    required String accessToken,
    required List<String> accts,
  }) async {
    if (accts.isEmpty) return const {};
    try {
      final response = await _dio.post(
        '$baseUrl/account/is_cat',
        data: {'accts': accts},
        options: _bearerOptions(accessToken),
      );
      final data = response.data as Map<String, dynamic>? ?? {};
      return {
        for (final entry in data.entries)
          entry.key: entry.value == null ? null : entry.value == true,
      };
    } catch (_) {
      return null;
    }
  }
}

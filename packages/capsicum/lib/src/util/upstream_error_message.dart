import 'package:dio/dio.dart';

import 'misskey_api_error.dart';

/// 上流（Misskey / Mastodon）が返したエラー理由を、ユーザーに提示できる短い
/// 日本語の「理由」に解決する (#886)。解決できなければ null を返し、呼び出し側の
/// 汎用文言に倒す。
///
/// ## なぜ今できるようになったか
///
/// モロヘイヤは以前、上流のボディを捨てて `{"error": "Bad response NNN"}` に
/// 潰していたため、`TOO_MANY_DRAFTS` と他の 400 を区別できなかった。#879 が
/// 「メッセージ改善は不可」で閉じたのはこれが理由。mulukhiya#4480（5.31.0）で
/// **上流のボディをそのまま透過する**ようになり（`Controller#handle_gateway_error`
/// が `error.source_body` を素通しする）、プリセットサーバー経由でも本来の
/// `error.code` が capsicum まで届く。
///
/// ## 受け取る形（実測・2026-08-12）
///
/// - **Misskey**: `error` は**オブジェクト** —
///   `{"error":{"code":"TOO_MANY_DRAFTS","message":"...","id":"...","kind":"client"}}`
/// - **Mastodon**: `error` は**文字列** — `{"error":"Validation failed: ..."}`
/// - モロヘイヤ自身が文言を出す 413（アップロード上限）も文字列で来る
///
/// 次の場合は従来どおり `{"error": "Bad response NNN"}`（文字列）へ倒れるので、
/// 理由として採用しない（[_looksPresentable] で弾く）: 上流が JSON を返さない
/// （nginx の HTML 502 等）/ 上流ボディが 65,536 バイト超。
/// **404 だけは透過が効かず** Sinatra の `not_found` が
/// `{"package":"ginseng-core","class":"Ginseng::NotFoundError",...}` に差し替える
/// （mulukhiya#4520）。`error` キー自体が無いので自然に null へ落ちる。
///
/// ## 方針
///
/// - **既知の Misskey コードだけを日本語に訳す。** 未知コードで Misskey の英語
///   `message`（`"Some files are not found."` 等）へ倒すことはしない。日本語の
///   汎用文言より不親切になるため。コード自体は Sentry のタグへ回して観測する。
/// - **Mastodon は定型句だけ訳し、残りは英語のまま出す** (#976)。あちらの
///   `error` は人間向けの散文で、クライアントに見せる前提のもの。実際に踏む
///   定型句（[_mastodonErrorPhrases]）だけ日本語へ寄せ、それ以外は英語のまま
///   出す。⚠ **どれが本当に英語で届くかは [_localizeMastodonError] の doc が
///   正本**（I18n を通る形は ja アカウントでは日本語で届く・#1027-C3）。
///   ⚠ これは取りこぼしではなく**意図した非対称**（Misskey の未知は
///   `SOME_ERROR_CODE` という機械語だが、Mastodon の未知は曲がりなりにも
///   文章になっている）。機械的な残骸・巨大ボディは従来どおり弾く。
/// - **`errors`（複数形・配列）も見る** (#976)。モロヘイヤ独自 API の
///   バリデーション失敗はこの形で返る。
String? upstreamErrorMessage(Object error, {required String reblogLabel}) {
  final code = misskeyApiErrorCode(error);
  if (code != null) {
    // Misskey 形（オブジェクト）と分かった時点で、未知コードでも文字列側へは
    // 落とさない。`error` は Map なので [_mastodonErrorText] は元々 null を返すが、
    // 意図として明示しておく。
    return misskeyErrorReason(code, reblogLabel: reblogLabel);
  }
  return _mastodonErrorText(error);
}

/// [fallback]（「下書きの保存に失敗しました」等の汎用文言）に、解決できた上流の
/// 理由を添えた 1 行を返す。解決できなければ [fallback] をそのまま返す。
///
/// 表示の組み立てをここ 1 箇所に閉じ、呼び出し側ごとに「理由を括弧書きにするか
/// 改行するか」が割れないようにする。
String upstreamFailureText(
  String fallback,
  Object error, {
  required String reblogLabel,
}) {
  final reason = upstreamErrorMessage(error, reblogLabel: reblogLabel);
  return reason == null ? fallback : '$fallback: $reason';
}

/// Misskey の `error.code` に対応する日本語の理由。未知コードは null。
///
/// 収録範囲は **モロヘイヤが横取りしているエンドポイント**（`notes/create` /
/// `notes/drafts/{create,update}` / `notes/favorites/create` /
/// `notes/reactions/create` / `drive/files/create`）が宣言するコード＝
/// `MisskeyController::USER_FAULT_CODES` に揃えてある。capsicum に届きうるのは
/// この範囲なので、闇雲に全コードを並べない。
///
/// 上流がコードを増やしても、ここに無ければ汎用文言に倒れるだけで壊れない。
///
/// [reblogLabel] は [reblogLabelProvider] の値を渡す。理由は
/// [_misskeyErrorReasons] の doc を参照。
String? misskeyErrorReason(String code, {required String reblogLabel}) =>
    _misskeyErrorReasons[code]?.replaceAll(reblogPlaceholder, reblogLabel);

/// [_misskeyErrorReasons] の文面で「ブースト / リノート / リキュア！」の位置を
/// 表す差し込み記号 (#1027-C2)。
const reblogPlaceholder = '{reblog}';

/// 収録済みのコード一覧。**検査が母数をソースから取れるように**公開している
/// （#1027-C2）。テスト側に一覧を写すと、コードを足したときに検査が付いてこない。
Iterable<String> get misskeyErrorCodes => _misskeyErrorReasons.keys;

/// **文面に上限値の数字を書かない。** `noteDraftLimit` / `scheduledNoteLimit` は
/// Misskey のロールポリシー（既定 10 だがロールで変わる）なので、「10 件までです」と
/// 決め打ちすると上限を引き上げたサーバーで嘘になる。実際の値は `/api/i` の
/// `policies` に出るが、エラー時に追加の API を叩いてまで数字を出す価値は薄い。
///
/// ⚠⚠ **「ブースト」「リノート」を直書きしない (#1027-C2)。**用語の正本は
/// `reblogLabelProvider`（モロヘイヤの `reblog_label` → `ReactionSupport` の
/// 有無、の優先順）。ここは Misskey 専用の表なので素朴には「リノート」だが、
/// **きゅあすきーは「リキュア！」**なので直書きすると**そのサーバーだけ
/// エラー文言だけが他の全 UI と食い違う**。[reblogPlaceholder] を置き、
/// 表示直前に差し替える。
///
/// 初版は「ブースト」で統一されており、Misskey 専用の表なのに Mastodon 側の
/// 用語になっていた（v1.60 リリース前レビュー）。
const _misskeyErrorReasons = <String, String>{
  // 下書き / 予約投稿（#879 の発端はここ）。
  'TOO_MANY_DRAFTS': '下書きの数が上限に達しています。不要な下書きを削除してください',
  'TOO_MANY_SCHEDULED_NOTES': '予約投稿の数が上限に達しています。不要な予約投稿を削除してください',
  'NO_SUCH_NOTE_DRAFT': '対象の下書きが見つかりません。他の端末で削除された可能性があります',
  'SCHEDULED_AT_REQUIRED': '予約日時が指定されていません',
  'SCHEDULED_AT_MUST_BE_IN_FUTURE': '予約日時には未来の時刻を指定してください',

  // 投稿の内容・宛先。
  'CONTAINS_PROHIBITED_WORDS': 'サーバーで禁止されている単語が含まれています',
  'CONTAINS_TOO_MANY_MENTIONS': 'メンションの数が上限を超えています',
  'CANNOT_CREATE_ALREADY_EXPIRED_POLL': '締め切りが過去のアンケートは作成できません',
  'YOU_HAVE_BEEN_BLOCKED': '相手にブロックされています',
  'ACCESS_DENIED': 'この操作は許可されていません',

  // 対象が見つからない系。ユーザーから見ると原因は同じ（消えた / 見えない）
  // なので、投稿・添付・チャンネルの別だけ分ける。
  'NO_SUCH_NOTE': '対象の投稿が見つかりません。削除された可能性があります',
  'NO_SUCH_RENOTE': '対象の投稿が見つかりません。削除された可能性があります',
  'NO_SUCH_RENOTE_TARGET': '対象の投稿が見つかりません。削除された可能性があります',
  'NO_SUCH_REPLY': '返信先の投稿が見つかりません。削除された可能性があります',
  'NO_SUCH_REPLY_TARGET': '返信先の投稿が見つかりません。削除された可能性があります',
  'NO_SUCH_CHANNEL': '対象のチャンネルが見つかりません',
  'NO_SUCH_FILE': '添付ファイルが見つかりません',

  // リノートの可否。Misskey は条件ごとに別コードを返す。
  'CANNOT_RENOTE': 'この投稿は{reblog}できません',
  'CANNOT_RENOTE_DUE_TO_VISIBILITY': '公開範囲の設定により、この投稿は{reblog}できません',
  'CANNOT_RENOTE_OUTSIDE_OF_CHANNEL': 'チャンネルの外へは{reblog}できません',
  'CANNOT_RENOTE_TO_A_PURE_RENOTE': '{reblog}そのものは{reblog}できません',
  'CANNOT_RENOTE_TO_EXTERNAL': '外部のサーバーへは{reblog}できません',
  'CANNOT_REACT_TO_RENOTE': '{reblog}にはリアクションできません',

  // 返信の可否。
  'CANNOT_REPLY_TO_AN_INVISIBLE_NOTE': '見えない投稿には返信できません',
  'CANNOT_REPLY_TO_A_PURE_RENOTE': '{reblog}そのものには返信できません',
  'CANNOT_REPLY_TO_SPECIFIED_NOTE_WITH_EXTENDED_VISIBILITY':
      '公開範囲の設定により、この投稿には返信できません',
  'CANNOT_REPLY_TO_SPECIFIED_VISIBILITY_NOTE_WITH_EXTENDED_VISIBILITY':
      '公開範囲の設定により、この投稿には返信できません',

  // ドライブ（添付のアップロード）。
  'MAX_FILE_SIZE_EXCEEDED': 'ファイルサイズがサーバーの上限を超えています',
  'NO_FREE_SPACE': 'ドライブの空き容量が足りません',
  'UNALLOWED_FILE_TYPE': 'この形式のファイルはアップロードできません',
  'INVALID_FILE_NAME': 'ファイル名が正しくありません',
  'INAPPROPRIATE': '不適切な内容を含む可能性があると判定されました',

  // 冪等系。アダプタ側で成功に吸収している (#873 / #877) ので通常は表に出ないが、
  // 別経路から漏れたときに「失敗しました」だけ出るより親切。
  'ALREADY_FAVORITED': 'すでに登録済みです',
  'ALREADY_REACTED': 'すでにリアクション済みです',
};

/// Mastodon 形（`error` が文字列）の理由。提示に耐えない残骸は null にする。
///
/// ⚠ **`errors`（複数形・配列）も見る (#976)。**モロヘイヤ独自 API の
/// バリデーション失敗は `{"errors":["タグは 10 個までです", ...]}` で返る
/// （予約投稿のタグ更新 `PUT /mulukhiya/api/scheduled_status/:id/tags` 等）。
/// `error` しか見ていなかったため、**その画面の主要な失敗ケースには #886 が
/// 効いていなかった**。
String? _mastodonErrorText(Object error) {
  if (error is! DioException) return null;
  final data = error.response?.data;
  if (data is! Map) return null;

  final text = data['error'];
  if (text is String) {
    final trimmed = text.trim();
    if (!_looksPresentable(trimmed)) return null;
    return _localizeMastodonError(trimmed);
  }

  final errors = data['errors'];
  if (errors is List) {
    // 要素は文字列想定。Rails 流儀で `{field: [msg]}` が来る実装もあるので、
    // 文字列以外は黙って捨てる（部分的にでも理由が出るほうがよい）。
    final joined = errors
        .whereType<String>()
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty);
    if (joined.isEmpty) return null;
    // ⚠ **全部つながない。**SnackBar に載る長さに収める。件数が多いときは
    // 先頭だけ出して「ほか N 件」を添える。
    final list = joined.toList();
    final head = list.first;
    final combined = list.length == 1 ? head : '$head（ほか ${list.length - 1} 件）';
    return _looksPresentable(combined) ? combined : null;
  }
  return null;
}

/// Mastodon がよく返す英語の `error` を日本語へ寄せる (#976)。
///
/// ## どの文言が実際に英語で届くか（#1027-C3・フォークのソースで確定）
///
/// ⚠⚠ **「多数派の環境ほど英語が出る」は半分しか正しくない。**`Api::BaseController`
/// は `ApplicationController` 経由で `Localized` を include しており、
/// `set_locale` が **`current_user.locale` を見る**。つまり**ロケールが `ja` の
/// アカウントには、I18n を通る文言は日本語で届く**。
///
/// | capsicum が訳している文言 | サーバー側 | ja アカウントに届くもの |
/// | --- | --- | --- |
/// | `character limit of N exceeded` | `I18n.t('statuses.over_character_limit')` | **日本語**（「上限は500文字です」） |
/// | `X is too long (maximum is N characters)` | ActiveRecord 既定 | **日本語** |
/// | `Text can't be blank` | ActiveRecord 既定 | **日本語** |
/// | `Record not found` | **ハードコード**（`concerns/api/error_handling.rb`） | **英語** |
/// | `This action is not allowed` | **ハードコード**（同上） | **英語** |
/// | `Your login is currently disabled` | **ハードコード**（`application_controller.rb`） | **英語** |
/// | `The access token is invalid` / `was revoked` | doorkeeper に ja 訳あり | **英語**（未認証で `current_user` が無く、capsicum は `Accept-Language` を送らないので `default_locale` へ落ちる） |
///
/// ⚠ **上 3 つ（I18n を通る形）の訳は ja アカウントでは発火しない。**ただし
/// **消す理由も無い** — `en` ロケールのアカウントでは実際に英語で届くし、
/// サーバー側の日本語はそのまま素通しされるので害も無い。
///
/// ⚠ **下 4 つ（ハードコード）はロケールに関係なく英語**なので、ここの訳が
/// 実質の効き所。**「英語が出る」という動機を疑うときは、まず I18n を通る形か
/// ハードコードかを分けること。**
///
/// ⚠ **未知の文言は英語のまま出す。**これは上の「方針」で意図的に決めた挙動
/// （Mastodon の `error` は人間向けの散文で、クライアントに見せる前提）。
/// Misskey の未知コードを落とす扱いとは非対称だが、あちらは `SOME_ERROR_CODE`
/// という機械語なのに対し、こちらは曲がりなりにも文章になっている。
/// **「英語が出るのは承知の上」**であって、取りこぼしではない。
String _localizeMastodonError(String text) {
  // 本文の長さ超過。上限値はサーバー設定で変わるので、**数字は文面から拾って
  // そのまま使う**（決め打ちすると上限を変えたサーバーで嘘になる）。
  final statusTooLong = _mastodonStatusTooLong.firstMatch(text);
  if (statusTooLong != null) {
    return '本文が長すぎます（上限 ${statusTooLong.group(1)} 文字）';
  }
  final fieldTooLong = _mastodonFieldTooLong.firstMatch(text);
  if (fieldTooLong != null) {
    final label = _mastodonFieldLabels[fieldTooLong.group(1)];
    final max = fieldTooLong.group(2);
    return label == null ? '入力が長すぎます（上限 $max 文字）' : '$labelが長すぎます（上限 $max 文字）';
  }
  for (final entry in _mastodonErrorPhrases.entries) {
    if (text.contains(entry.key)) return entry.value;
  }
  return text;
}

/// 本文（投稿テキスト）の長さ超過。
///
/// ⚠⚠ **Rails 既定の `is too long (maximum is N characters)` ではない。**
/// Mastodon は `StatusLengthValidator` で専用の I18n キー
/// (`statuses.over_character_limit` = `character limit of %{max} exceeded`) を
/// 使うため、実際に返るのは
/// `Validation failed: Text character limit of 3000 exceeded`。
///
/// #976 の初版は Rails 既定形を書いており、**一度も発火しない**まま出荷される
/// ところだった。テストがコード側で組み立てた架空の文字列を assert していたので
/// 緑のまま通っていた（v1.60 のリリース前レビューで検出）。**上流の文面は
/// フォーク (`~/repos/mastodon`) で確かめること。**
///
/// この I18n キーを引くのは `status_length_validator.rb` の `:text` だけなので、
/// 当たったら本文と言い切ってよい。
final _mastodonStatusTooLong = RegExp(r'character limit of (\d+) exceeded');

/// ActiveRecord 既定形の長さ超過。**フィールド名まで見る。**
///
/// ⚠ **フィールドを見ずに「本文」と訳してはいけない（Codex P2 / PR #1023）。**
/// この形で返るのは通報コメント (`Report::COMMENT_SIZE_LIMIT`)・ユーザーメモ・
/// 招待コメント・メディアの説明・アバターの説明などで、**本文だけは上の専用
/// キーを使うので絶対にここへ来ない**。それでも初版は両方を 1 本の正規表現で
/// 受けて一律「本文が長すぎます」と訳しており、テストが
/// `Comment is too long` → 「本文が長すぎます」を**正解として固定していた**。
///
/// 素性の分かっているものだけ名前を付け、それ以外は field 中立に倒す。ここに
/// 無いフィールドを勝手に名指しすると、また同じ誤訳になる。
final _mastodonFieldTooLong = RegExp(
  r'([A-Za-z][A-Za-z ]*?) is too long \(maximum is (\d+) characters\)',
);

const _mastodonFieldLabels = <String, String>{
  'Comment': 'コメント',
  'Description': '説明',
};

/// 素通しでは意味が取りにくい定型句だけを訳す。
///
/// ⚠ **網羅しない。**上流の文面は版で変わるので、増やすのは「実際に踏んだ」
/// ものに限る。ここに無ければ英語のまま出るだけで壊れない。
const _mastodonErrorPhrases = <String, String>{
  "Text can't be blank": '本文が空です',
  'Record not found': '対象が見つかりません。削除された可能性があります',
  'This action is not allowed': 'この操作は許可されていません',
  'The access token is invalid': 'ログイン情報が無効です。ログインし直してください',
  'The access token was revoked': 'ログイン情報が失効しています。ログインし直してください',
  'Your login is currently disabled': 'このアカウントは現在利用できません',
};

/// そのまま画面に出してよい文字列か。
///
/// - 空 → 出さない
/// - `Bad response NNN` → **透過できなかったときのモロヘイヤの残骸**。上流が JSON を
///   返さない（nginx の HTML 502 等）／ボディが 65,536 バイト超のときに来る。
///   ユーザーには意味がないので汎用文言に倒す
/// - 複数行 / 長すぎる → SnackBar に載らないうえ、HTML 断片や stack trace の
///   混入が疑われる
bool _looksPresentable(String text) {
  if (text.isEmpty) return false;
  if (_legacyFlattenedError.hasMatch(text)) return false;
  if (text.contains('\n')) return false;
  if (text.length > _maxPresentableLength) return false;
  return true;
}

const _maxPresentableLength = 200;

/// mulukhiya#4480 以前の（そして今も fallback で使われる）`Bad response NNN`。
final _legacyFlattenedError = RegExp(r'^Bad response \d+$');

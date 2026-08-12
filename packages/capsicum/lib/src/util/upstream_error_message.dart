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
/// - **Mastodon の文字列はそのまま出す。** あちらの `error` は人間向けの散文で、
///   クライアントに見せる前提のもの。ただし機械的な残骸・巨大ボディは弾く。
String? upstreamErrorMessage(Object error) {
  final code = misskeyApiErrorCode(error);
  if (code != null) {
    // Misskey 形（オブジェクト）と分かった時点で、未知コードでも文字列側へは
    // 落とさない。`error` は Map なので [_mastodonErrorText] は元々 null を返すが、
    // 意図として明示しておく。
    return misskeyErrorReason(code);
  }
  return _mastodonErrorText(error);
}

/// [fallback]（「下書きの保存に失敗しました」等の汎用文言）に、解決できた上流の
/// 理由を添えた 1 行を返す。解決できなければ [fallback] をそのまま返す。
///
/// 表示の組み立てをここ 1 箇所に閉じ、呼び出し側ごとに「理由を括弧書きにするか
/// 改行するか」が割れないようにする。
String upstreamFailureText(String fallback, Object error) {
  final reason = upstreamErrorMessage(error);
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
String? misskeyErrorReason(String code) => _misskeyErrorReasons[code];

/// **文面に上限値の数字を書かない。** `noteDraftLimit` / `scheduledNoteLimit` は
/// Misskey のロールポリシー（既定 10 だがロールで変わる）なので、「10 件までです」と
/// 決め打ちすると上限を引き上げたサーバーで嘘になる。実際の値は `/api/i` の
/// `policies` に出るが、エラー時に追加の API を叩いてまで数字を出す価値は薄い。
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

  // ブースト（リノート）の可否。Misskey は条件ごとに別コードを返す。
  'CANNOT_RENOTE': 'この投稿はブーストできません',
  'CANNOT_RENOTE_DUE_TO_VISIBILITY': '公開範囲の設定により、この投稿はブーストできません',
  'CANNOT_RENOTE_OUTSIDE_OF_CHANNEL': 'チャンネルの外へはブーストできません',
  'CANNOT_RENOTE_TO_A_PURE_RENOTE': 'ブーストそのものはブーストできません',
  'CANNOT_RENOTE_TO_EXTERNAL': '外部のサーバーへはブーストできません',
  'CANNOT_REACT_TO_RENOTE': 'ブーストにはリアクションできません',

  // 返信の可否。
  'CANNOT_REPLY_TO_AN_INVISIBLE_NOTE': '見えない投稿には返信できません',
  'CANNOT_REPLY_TO_A_PURE_RENOTE': 'ブーストそのものには返信できません',
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
String? _mastodonErrorText(Object error) {
  if (error is! DioException) return null;
  final data = error.response?.data;
  if (data is! Map) return null;
  final text = data['error'];
  if (text is! String) return null;
  final trimmed = text.trim();
  return _looksPresentable(trimmed) ? trimmed : null;
}

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

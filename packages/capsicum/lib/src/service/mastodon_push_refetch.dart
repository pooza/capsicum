import 'package:capsicum_backends/capsicum_backends.dart'
    show mastodonMutedAlertTypes;
import 'package:capsicum_core/capsicum_core.dart' show PushAlertCategory;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/widget/content_parser.dart' show stripHtml;
import 'account_storage.dart';
import 'push_failure_recorder.dart';
import 'push_message_dispatcher.dart' show DecryptedPushContent;
import 'push_muted_alerts.dart';

/// 復号できなかった Mastodon 系のプッシュを、API で最新の通知を引き直して
/// 中身つきで出す（Android・#1426）。
///
/// ⚠ **なぜ復号できない 1 通が届くのか。**上流のサーバーに、同じ宛先への古い
/// 購読（以前のログインのトークンに付いたもの）が残っていると、同じ通知が
/// 別々の鍵で複数通届く。relay の重複の抑止（capsicum-relay の
/// `push_dedup.rb`・#692）は最初に着いた 1 通だけを通すので、**古い鍵の 1 通が
/// 勝つと端末では読めない**。どれが勝つかはその場の運で、今の鍵の 1 通が届く
/// とは限らない。
///
/// iOS の NSE が Misskey の縮退した通知を引き直す仕組み（#1215・
/// `NotificationService.swift` の `DegradedRefetch`）と同じ守りを持つ:
///
/// - 作られてから [freshness] 以内の通知だけを採る（古い通知を新着として
///   出さない）
/// - 出した通知の id を [shownIdsLimit] 件まで控え、同じ通知を二度出さない。
///   復号できた通知の id も [noteShown] で控える（取り直しと二重にならない）
///
/// ⚠ 対象は Mastodon 系（Akkoma を含む・保存先が `mastodon://`）だけ。
/// トークンは本体の [AccountStorage] から読む（Android はアプリ本体の Dart が
/// バックグラウンドで動くので、iOS の NSE のような写しは要らない）。
class MastodonPushRefetch {
  MastodonPushRefetch._();

  /// 採る通知の新しさ。iOS の NSE と同じ。
  static const freshness = Duration(seconds: 60);

  /// 控えておく id の数。iOS の NSE と同じ。
  static const shownIdsLimit = 8;

  static const _shownIdsPrefix = 'capsicum_push_shown_ids_';

  /// テストで差し替える。
  @visibleForTesting
  static Dio Function() dioFactory = () => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ),
  );

  /// テストで差し替える。
  @visibleForTesting
  static Future<String?> Function(String storageKey) tokenReader = _readToken;

  static Future<String?> _readToken(String storageKey) async {
    final secrets = await AccountStorage().getSecrets(storageKey);
    return secrets?['access_token'];
  }

  /// テストで差し替える。`mastodon://username@host` の、受け取らない分類（#1411）。
  @visibleForTesting
  static Future<Set<PushAlertCategory>> Function(String storageKey)
  mutedReader = PushMutedAlerts.readMutedFor;

  /// [account]（`username@host`）の最新の通知を引き、使えるなら中身を返す。
  /// 使えない・引けないときは null（呼び出し側は汎用の文面のまま出す）。
  ///
  /// 引けなかった・使わなかったときは [onFailure] に種類（`network` / `http_401` /
  /// `muted` など）を渡す。⚠ **ここでは失敗を記録しない。**呼び出し側が直前に
  /// 書いた復号の失敗の記録（[PushFailureRecorder] は 1 枠）を上書きして、#1426
  /// で見たい `decryptError` を消してしまうため。呼び出し側が
  /// [PushFailureRecorder.annotateRefetch] で書き足す。
  ///
  /// ⚠ **受け取らない分類（#1411）の通知は出さない**（`muted`）。古い購読は全種類を
  /// 送ってくるので、切った種類の 1 通が復号できずに届くことがある。
  /// ⚠⚠ **`exclude_types[]` で除いて引かない**（2 巡目のレビュー・v2.15）。除くと、
  /// 届いた 1 通（切った種類）ではなく 1 つ前の受け取る通知が返り、鮮度と控えを
  /// すり抜けたときに関係のない通知を新着として出す。除かずに最新の 1 件を引き、
  /// 種類を見て捨てる。
  static Future<DecryptedPushContent?> fetchLatest(
    String account, {
    DateTime Function() now = DateTime.now,
    void Function(String kind)? onFailure,
  }) async {
    final at = account.lastIndexOf('@');
    if (at <= 0 || at == account.length - 1) return null;
    final host = account.substring(at + 1);
    final storageKey = 'mastodon://$account';

    final String? token;
    try {
      token = await tokenReader(storageKey);
    } catch (_) {
      _fail('token', onFailure);
      return null;
    }
    // Mastodon 系のアカウントでない（Misskey など）か、ログインしていない。
    // ⚠ 失敗として記録しない —— 対象外なだけ。
    if (token == null || token.isEmpty) return null;

    final mutedTypes = mastodonMutedAlertTypes(await mutedReader(storageKey));

    final Object? data;
    try {
      final response = await dioFactory().get<Object?>(
        'https://$host/api/v1/notifications',
        queryParameters: {'limit': 1},
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      data = response.data;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      _fail(status != null ? 'http_$status' : 'network', onFailure);
      return null;
    } catch (_) {
      _fail('network', onFailure);
      return null;
    }

    if (data is! List) {
      _fail('parse', onFailure);
      return null;
    }
    // 0 件は失敗ではない（通知を消した直後など）。汎用の文面のまま。
    if (data.isEmpty) return null;
    final latest = data.first;
    if (latest is! Map<String, dynamic>) {
      _fail('parse', onFailure);
      return null;
    }
    return accept(
      latest,
      account: account,
      now: now(),
      mutedTypes: mutedTypes,
      onFailure: onFailure,
    );
  }

  /// [fetchLatest] が [onFailure] に渡す種類のうち、呼び出し側が通知を**出さない**
  /// もの（汎用の文面も出さない）。
  ///
  /// - `muted`: 最新の 1 件が受け取らない種類（#1411）＝届いた 1 通は切った種類
  /// - `shown`: 最新の 1 件はもう出した ＝ 届いた 1 通は同じ通知の写し
  ///
  /// ⚠ 引けなかった・古い・0 件はここに入れない（届いた 1 通が何だったか
  /// 分からないので、汎用の文面で知らせる）。
  static const suppressingKinds = {'muted', 'shown'};

  /// 引いた通知を使ってよいかを決め、使うなら中身を返す（控えにも足す）。
  ///
  /// [mutedTypes] は受け取らない Mastodon の種別（`favourite` など・#1411）。
  @visibleForTesting
  static Future<DecryptedPushContent?> accept(
    Map<String, dynamic> notification, {
    required String account,
    required DateTime now,
    Set<String> mutedTypes = const {},
    void Function(String kind)? onFailure,
  }) async {
    final id = notification['id'];
    if (id is! String || id.isEmpty) return null;
    // ⚠ 鮮度を先に見る。古い 1 件は届いた 1 通とは別の通知なので、種類で
    // 黙らせない（汎用の文面のまま出す）。
    if (!isFresh(notification, now)) return null;
    // 失敗ではないが、呼び出し側が出さないと決めるのと、Sentry で「使わな
    // かった」の内訳を分けて見るために渡す（[suppressingKinds]）。
    final type = notification['type'];
    if (type is String && mutedTypes.contains(type)) {
      _fail('muted', onFailure);
      return null;
    }
    if (await _wasShown(id, account)) {
      _fail('shown', onFailure);
      return null;
    }
    await noteShown(id, account);
    return contentFromNotification(notification);
  }

  /// 作られてから [freshness] 以内か。日時が読めなければ false。
  @visibleForTesting
  static bool isFresh(Map<String, dynamic> notification, DateTime now) {
    final raw = notification['created_at'];
    if (raw is! String) return false;
    final createdAt = DateTime.tryParse(raw);
    if (createdAt == null) return false;
    final age = now.toUtc().difference(createdAt.toUtc());
    return age <= freshness;
  }

  /// Mastodon の通知（`GET /api/v1/notifications` の 1 件）を、プッシュを
  /// 復号したときと同じ形に直す。
  ///
  /// 見出しは呼び出し側が `type` から作るので、ここでは本文だけを組む:
  /// - 投稿がある → CW があれば CW の見出しだけ（本文は出さない・#1282 と同じ）、
  ///   無ければ投稿の本文
  /// - 投稿が無い（フォローなど）→ 相手の表示名（空なら `@acct`）
  @visibleForTesting
  static DecryptedPushContent contentFromNotification(
    Map<String, dynamic> notification,
  ) {
    final type = notification['type'];
    String? body;
    final status = notification['status'];
    if (status is Map<String, dynamic>) {
      final spoiler = status['spoiler_text'];
      if (spoiler is String && spoiler.trim().isNotEmpty) {
        body = spoiler.trim();
      } else {
        final content = status['content'];
        if (content is String) body = stripHtml(content).trim();
      }
    }
    if (body == null || body.isEmpty) {
      final from = notification['account'];
      if (from is Map<String, dynamic>) {
        final name = from['display_name'];
        final acct = from['acct'];
        if (name is String && name.trim().isNotEmpty) {
          body = name.trim();
        } else if (acct is String && acct.isNotEmpty) {
          body = '@$acct';
        }
      }
    }
    return DecryptedPushContent(
      body: (body == null || body.isEmpty) ? null : body,
      type: type is String ? type : null,
      notificationId: notification['id'] as String?,
    );
  }

  /// 通知を出した（または引き直しで使った）ことを控える。
  static Future<void> noteShown(String id, String account) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_shownIdsPrefix$account';
      final ids = List<String>.of(prefs.getStringList(key) ?? const [])
        ..remove(id)
        ..add(id);
      if (ids.length > shownIdsLimit) {
        ids.removeRange(0, ids.length - shownIdsLimit);
      }
      await prefs.setStringList(key, ids);
    } catch (_) {
      // 控えられなくても通知は出す（二重に出るほうが、出ないよりよい）。
    }
  }

  static Future<bool> _wasShown(String id, String account) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList('$_shownIdsPrefix$account')?.contains(id) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static void _fail(String kind, void Function(String kind)? onFailure) {
    debugPrint('capsicum: push.refetch: failed ($kind)');
    onFailure?.call(kind);
  }
}

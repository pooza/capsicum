import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// 覚えておく署名の上限。
///
/// ⚠ **上限が要るのは、署名が無限に増えうるから。**`describeConversionFailure`
/// は `FormatException` のメッセージをそのまま含むので、位置が違うだけの
/// 「ほぼ同じ失敗」が別の署名になりうる。上限が無いと、抑止のための集合が
/// そのままメモリを食う。
const _maxSignatures = 64;

/// 変換スキップの署名（どこで・どんな失敗か）を覚えておく集合 (#1035-B2)。
///
/// ⚠ **キーに投稿 ID は入れない。**入れると全件が別の署名になり、抑止が
/// まったく効かなくなる（＝この修正の目的が消える）。
///
/// ⚠ **`BoundedKeySet` を使わないのは、あちらが push 専用の観測を持つため。**
/// 押し出し時に `push.dedup.evicted`（`phase: push_dedup`）を送るので、変換
/// スキップの抑止に流用すると**無関係な事象が push の群に混ざる**。ここで
/// 押し出しが起きても意味は「同じ署名をもう一度送りうる」だけなので、観測は
/// 要らない。`Set` リテラルは `LinkedHashSet` なので `first` が最古になる。
final Set<String> _reportedSignatures = {};

/// 変換スキップを Sentry へ記録する。**同じ署名は 1 プロセスに 1 回だけ**。
///
/// ⚠⚠ **1 件 1 通で送らない (#1035-B2)。**初版は skip 1 件につき
/// `captureMessage` を 1 通送っていた。#741 の Collections 通知のような
/// **サーバー側の系統的な非対応**では 1 ページ 30 件が毎回全滅するので、
/// 通知ポーリング（バックグラウンド含む）のたびに 30 通が積まれていた。
/// 他の観測点（`_reportOnce` / `_reportRestoreOnce` / [BoundedKeySet]）は
/// いずれも per-process 1 回に絞っており、ここだけ方針が違った。
///
/// **初回に「そのバッチで何件落ちたか」を載せる**ことで、抑止しても「1 件だけ
/// 変な投稿があった」と「全部落ちている」を区別できるようにしてある。⚠ 抑止
/// されるのは**同じ署名の 2 通目以降**なので、新しい壊れ方は必ず 1 通出る。
///
/// 送るのは投稿 ID と変換エラー文字列のみで、本文は載せない
/// （[SkippedPost.error] は `describeConversionFailure` を通した値）。
void reportSkippedConversions(
  List<SkippedPost> skipped, {
  required String message,
  required String source,
  required String idHintKey,
  String? maxId,
}) {
  if (skipped.isEmpty) return;
  try {
    for (final item in skipped) {
      // 署名は「メッセージ（投稿 / 通知）× 発生元 × 失敗の中身」。
      if (!_reportedSignatures.add('$message|$source|${item.error}')) continue;
      while (_reportedSignatures.length > _maxSignatures) {
        _reportedSignatures.remove(_reportedSignatures.first);
      }
      // params は logentry.params として実際に送られる（hint は送られない）ので、
      // ここが変換失敗の唯一の観測経路 (#1027-A5)。
      // scrub-guard: allow: item.error は describeConversionFailure 済み（本文なし）
      Sentry.captureMessage(
        message,
        level: SentryLevel.warning,
        params: [item.id, item.error],
        hint: Hint.withMap({
          'source': source,
          idHintKey: item.id,
          'conversionError': item.error,
          'maxId': maxId ?? 'null',
          // このバッチで落ちた件数。1 なのか全滅なのかはここでしか分からない。
          'skippedInBatch': skipped.length,
        }),
      );
    }
  } catch (_) {
    // Sentry failure must not affect loading.
  }
}

/// 通知の変換失敗（malformed・#741 の Collections 通知等）を Sentry に記録する。
///
/// timeline 側の [reportSkippedPosts] (#777) と対称に、通知でも変換スキップを
/// 黙って捨てず観測する。これがないと `NotificationResponse.skippedPosts` が
/// 存在意義に挙げる #741 のケースが本番で完全に不可視になる。
/// [source] で発生元（single / unified）を区別し、[maxId] はページング位置。
void reportSkippedNotifications(
  List<SkippedPost> skipped, {
  required String source,
  String? maxId,
}) => reportSkippedConversions(
  skipped,
  message: 'Notification conversion failed',
  source: source,
  idHintKey: 'skippedNotificationId',
  maxId: maxId,
);

/// タイムラインの変換失敗を Sentry に記録する (#777)。
///
/// ⚠ **通知側と別の message を保つ。**Sentry では message が群の単位なので、
/// 揃えると「投稿が落ちている」と「通知が落ちている」が同じ issue に混ざる。
/// 共通化したのは抑止と件数の載せ方だけ。
void reportSkippedPosts(
  List<SkippedPost> skipped, {
  required String source,
  String? maxId,
}) => reportSkippedConversions(
  skipped,
  message: 'Post conversion failed',
  source: source,
  idHintKey: 'skippedPostId',
  maxId: maxId,
);

/// テスト用。プロセス内に溜めた署名を捨てる。
@visibleForTesting
void resetConversionSkipReportForTest() => _reportedSignatures.clear();

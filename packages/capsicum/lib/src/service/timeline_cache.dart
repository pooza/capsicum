import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../util/exception_scrub.dart';

/// 前回のホームタイムラインをディスクに残し、次の起動で即描画するための保存層
/// (#890)。
///
/// 保存するのは **サーバー応答の生 JSON**（`TimelineResponse.rawJson`）。読み出し
/// 側はアダプタの `decodeCachedPosts` で投稿へ戻す。ドメインモデルに codec を
/// 持たせるとモデル変更のたびに追従コストが乗るため、既存の `fromJson` を
/// そのまま使える生 JSON 方式を採る。
///
/// 保持するのは **起動直後に最初に見る 1 本（現在アカウントのホーム TL）だけ**。
/// タブ・アカウントごとに増やしても起動体感には効かず、ファイルが太るだけなので
/// 増やさない。文脈が変われば（別アカウント・別 TL 種別）キーが一致せず、単に
/// キャッシュ無しとして扱われる。
class TimelineCache {
  TimelineCache._();

  /// 保存する件数の上限。初回ページ（20 件）を超えて持っても最初の画面には
  /// 出ないため、そこで頭打ちにする。
  static const maxPosts = 20;

  /// これより古いキャッシュは使わない。数日前の TL を一瞬出しても意味が薄く、
  /// 「古い投稿が出た」という戸惑いのほうが大きいため。
  static const maxAge = Duration(hours: 24);

  static const _fileName = 'home_timeline_cache.json';

  /// テスト用の差し替え先。null なら path_provider の app support ディレクトリ。
  @visibleForTesting
  static String? directoryOverride;

  static Future<File> _file() async {
    final dir =
        directoryOverride ?? (await getApplicationSupportDirectory()).path;
    return File('$dir/$_fileName');
  }

  /// [contextKey] の TL の生 JSON を保存する。失敗しても呼び出し側は続行する
  /// （キャッシュは無くても動く）。
  static Future<void> save(
    String contextKey,
    List<Map<String, dynamic>> raw, {
    required DateTime now,
  }) async {
    if (raw.isEmpty) return;
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode({
          'contextKey': contextKey,
          'savedAt': now.toUtc().toIso8601String(),
          'posts': raw.take(maxPosts).toList(),
        }),
        flush: false,
      );
    } catch (e) {
      // 例外はそのまま出さない。release ビルドでは sentry_flutter の
      // DebugPrintIntegration が debugPrint を丸ごと breadcrumb 化するため、
      // FormatException.toString() が抱える source（＝このファイルに入っている
      // 投稿本文の断片）がそのまま Sentry へ送られる。#586 で用意した
      // scrubException を必ず通す。
      debugPrint('capsicum: timeline cache save failed: ${scrubException(e)}');
    }
  }

  /// [contextKey] に一致し、かつ [maxAge] 以内に保存されたキャッシュを返す。
  /// 一致しない・壊れている・古い場合は null。
  static Future<List<Map<String, dynamic>>?> load(
    String contextKey, {
    required DateTime now,
  }) async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      // 使えないと分かった時点で消す。保持期限や文脈が外れたキャッシュは以後
      // 二度と使われないのに、放っておくと投稿本文がディスクに残り続ける
      // （次の save で上書きされるまで、起動しなければ無期限）。
      if (decoded['contextKey'] != contextKey) return _discard();
      final savedAt = DateTime.tryParse('${decoded['savedAt']}');
      if (savedAt == null) return _discard();
      if (now.toUtc().difference(savedAt.toUtc()) > maxAge) return _discard();
      final posts = decoded['posts'];
      if (posts is! List) return _discard();
      return [
        for (final e in posts)
          if (e is Map<String, dynamic>) e,
      ];
    } catch (e) {
      // 壊れたファイルの jsonDecode 失敗がここに来る。scrub の理由は save 側の
      // コメントを参照（この経路が実際にいちばん踏まれる）。
      debugPrint('capsicum: timeline cache load failed: ${scrubException(e)}');
      return null;
    }
  }

  /// 使えないキャッシュを捨てて null を返す（[load] の各棄却枝から使う）。
  /// 削除は best-effort で、失敗しても読み出しの結果（使わない）は変わらない。
  static Null _discard() {
    unawaited(clear());
    return null;
  }

  /// キャッシュを消す。ログアウト等、残しておくと別アカウントに見えかねない
  /// 場面で呼ぶ。
  static Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('capsicum: timeline cache clear failed: ${scrubException(e)}');
    }
  }
}

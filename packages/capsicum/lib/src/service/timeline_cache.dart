import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

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
      debugPrint('capsicum: timeline cache save failed: $e');
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
      if (decoded['contextKey'] != contextKey) return null;
      final savedAt = DateTime.tryParse('${decoded['savedAt']}');
      if (savedAt == null) return null;
      if (now.toUtc().difference(savedAt.toUtc()) > maxAge) return null;
      final posts = decoded['posts'];
      if (posts is! List) return null;
      return [
        for (final e in posts)
          if (e is Map<String, dynamic>) e,
      ];
    } catch (e) {
      debugPrint('capsicum: timeline cache load failed: $e');
      return null;
    }
  }

  /// キャッシュを消す。ログアウト等、残しておくと別アカウントに見えかねない
  /// 場面で呼ぶ。
  static Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('capsicum: timeline cache clear failed: $e');
    }
  }
}

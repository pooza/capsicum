import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

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

  /// テスト用の差し替え先。null なら path_provider のキャッシュディレクトリ。
  @visibleForTesting
  static String? directoryOverride;

  /// 旧保存先 (Application Support) のテスト用差し替え先 (#914 §1)。
  @visibleForTesting
  static String? legacyDirectoryOverride;

  /// 保存先は**キャッシュ領域** (#914 §1)。
  ///
  /// 元は `getApplicationSupportDirectory()` に置いていたが、ここに入るのは
  /// **生のホーム TL** で、Mastodon の `filter_from_home` は visibility による
  /// 除外をしない（`app/lib/feed_manager.rb`）ため、フォロー相手からの
  /// フォロワー限定・ダイレクト投稿が載る。つまり **DM 本文がディスクに落ちる**。
  ///
  /// Application Support は iOS で**既定でバックアップ対象**なので、投稿本文が
  /// iCloud バックアップに入っていた。キャッシュ領域はバックアップ対象外で、
  /// 「消えても再取得すれば済む」という寿命もこの用途と一致する（24 時間 TTL で
  /// どのみち捨てる）。OS がキャッシュを掃除しても、キャッシュ無しの起動経路に
  /// 落ちるだけで壊れない。
  ///
  /// **Linux の他ユーザーからの可読性**は保存先だけでは塞げない（`0644` /
  /// `~/.cache/<app>/` も `0755`）ため、[_save] が書き込み後に `chmod 600` で
  /// 所有者のみ可読にする (#958)。
  static Future<File> _file() async {
    final dir =
        directoryOverride ?? (await getApplicationCacheDirectory()).path;
    return File('$dir/$_fileName');
  }

  /// 旧保存先 (Application Support) に残ったキャッシュを消す (#914 §1)。
  ///
  /// 保存先を移しただけだと、**旧ファイルは二度と読まれないまま残り続ける**
  /// （新しい保存先を使うので上書きもされない）。中身が投稿本文である以上、
  /// 移行時に消しておく必要がある。起動時に一度だけ呼ぶ。
  ///
  /// best-effort。失敗しても起動は止めない（次回起動で再試行される）。
  static Future<void> clearLegacyLocation() async {
    try {
      final dir =
          legacyDirectoryOverride ??
          (await getApplicationSupportDirectory()).path;
      final legacy = File('$dir/$_fileName');
      if (await legacy.exists()) {
        await legacy.delete();
        debugPrint('capsicum: timeline cache: removed legacy copy');
      }
    } catch (e) {
      debugPrint(
        'capsicum: timeline cache legacy cleanup failed: ${scrubException(e)}',
      );
      _reportIoFailureOnce('legacy_cleanup', e);
    }
  }

  /// 書き込み系の直列化キュー。
  ///
  /// 保存は `unawaited` で投げるので、ログアウトの [clear] と競合する。世代チェックは
  /// 「stale になった後に**保存を始めない**」ことしか保証できず、**既に始まっている
  /// 書き込み**は止められない。clear が先に終わってから遅れて write が完了すると、
  /// **ログアウトしたアカウントの生タイムラインがディスクに復活する**。save と clear を
  /// 同じキューに並べて順序を確定させる。
  static Future<void> _writeQueue = Future<void>.value();

  static Future<void> _serialize(Future<void> Function() op) {
    // 直前の失敗で鎖が切れないよう、成否にかかわらず次へ繋ぐ。
    final next = _writeQueue.then((_) => op(), onError: (_) => op());
    _writeQueue = next.catchError((_) {});
    return next;
  }

  /// [contextKey] の TL の生 JSON を保存する。失敗しても呼び出し側は続行する
  /// （キャッシュは無くても動く）。
  static Future<void> save(
    String contextKey,
    List<Map<String, dynamic>> raw, {
    required DateTime now,
  }) {
    if (raw.isEmpty) return Future<void>.value();
    return _serialize(() => _save(contextKey, raw, now));
  }

  static Future<void> _save(
    String contextKey,
    List<Map<String, dynamic>> raw,
    DateTime now,
  ) async {
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
      // Linux では他ユーザーから読めないよう 0600 に絞る (#958)。writeAsString は
      // 0644 で作り ~/.cache/<app>/ も 0755 なので、同ホストの別ユーザーが生の
      // ホーム TL（フォロワー限定 / DM 本文を含む）を読めてしまう。dart:io に
      // chmod が無いので chmod(1) を呼ぶ。best-effort（失敗しても保存は活かす）。
      if (Platform.isLinux) {
        try {
          await Process.run('chmod', ['600', file.path]);
        } catch (_) {
          // 権限設定に失敗しても保存自体は有効。
        }
      }
    } catch (e) {
      // 例外はそのまま出さない。release ビルドでは sentry_flutter の
      // DebugPrintIntegration が debugPrint を丸ごと breadcrumb 化するため、
      // FormatException.toString() が抱える source（＝このファイルに入っている
      // 投稿本文の断片）がそのまま Sentry へ送られる。#586 で用意した
      // scrubException を必ず通す。
      debugPrint('capsicum: timeline cache save failed: ${scrubException(e)}');
      _reportIoFailureOnce('save', e);
    }
  }

  /// キャッシュの読み書き失敗を **1 プロセス 1 回だけ** Sentry に上げる (#958)。
  ///
  /// 恒久的な失敗（ディスク満杯・サンドボックス拒否）で #890 の先出しが黙って
  /// 無効化されても、これまでは `from_cache` タグから間接推測するしかなかった。
  /// **生の例外文字列は載せない**（このファイルには投稿本文が入っており、
  /// `FormatException.toString()` 等が断片を抱えるため）。経路と例外型だけを
  /// タグにして 1 issue へ集約する。
  static bool _ioFailureReported = false;

  static void _reportIoFailureOnce(String op, Object e) {
    if (_ioFailureReported) return;
    _ioFailureReported = true;
    unawaited(
      Sentry.captureMessage(
        'timeline_cache.io_failure',
        level: SentryLevel.warning,
        withScope: (scope) {
          scope.setTag('cache.op', op);
          scope.setTag('cache.error', e.runtimeType.toString());
          scope.fingerprint = ['timeline_cache.io_failure'];
        },
      ),
    );
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
      _reportIoFailureOnce('load', e);
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
  ///
  /// **await すれば、先に始まっていた保存の完了後に消えることが保証される**
  /// （[_writeQueue] の説明を参照）。ログアウトはこれを await している。
  static Future<void> clear() => _serialize(_clear);

  static Future<void> _clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('capsicum: timeline cache clear failed: ${scrubException(e)}');
      _reportIoFailureOnce('clear', e);
    }
  }
}

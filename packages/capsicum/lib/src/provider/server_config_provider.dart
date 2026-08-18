import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../service/server_metadata_cache.dart';
import 'account_manager_provider.dart';
import 'preferences_provider.dart';
import '../util/exception_scrub.dart';
import '../util/login_error.dart';

/// Host → theme color map from mulukhiya services (logged-in servers only).
final hostThemeColorProvider = Provider<Map<String, Color>>((ref) {
  final accounts = ref.watch(accountManagerProvider).accounts;
  final map = <String, Color>{};
  for (final account in accounts) {
    final hex = account.mulukhiya?.themeColorHex;
    if (hex != null && hex.startsWith('#') && hex.length >= 7) {
      try {
        map[account.key.host] = Color(
          0xFF000000 | int.parse(hex.substring(1, 7), radix: 16),
        );
      } catch (_) {}
    }
  }
  return map;
});

/// Resolve theme color for a host.
/// Priority: mulukhiya → server API cache → deterministic fallback.
/// Mulukhiya colors are used as-is (designed as dark backgrounds for white text).
/// Other sources are adjusted to ensure sufficient contrast with white text.
Color resolveHostColor(Map<String, Color> mulukhiyaColors, String host) {
  final mulukhiya = mulukhiyaColors[host];
  if (mulukhiya != null) return mulukhiya;

  final cached = ServerMetadataCache.instance.getCached(host);
  final hex = cached?.themeColor;
  if (hex != null) {
    final parsed = _parseHexColor(hex);
    if (parsed != null) return _ensureDark(parsed);
  }

  // Deterministic fallback based on host hash.
  return HSLColor.fromAHSL(1, host.hashCode % 360, 0.5, 0.35).toColor();
}

/// Darken a color if it is too bright for white text.
Color _ensureDark(Color color) {
  final hsl = HSLColor.fromColor(color);
  if (hsl.lightness > 0.45) {
    return hsl.withLightness(0.35).toColor();
  }
  return color;
}

Color? _parseHexColor(String hex) {
  final raw = hex.startsWith('#') ? hex.substring(1) : hex;
  if (raw.length < 6) return null;
  try {
    return Color(0xFF000000 | int.parse(raw.substring(0, 6), radix: 16));
  } catch (_) {
    return null;
  }
}

/// The label to use for "post" actions (e.g. "キュア！" on precure.fun).
final postLabelProvider = Provider<String>((ref) {
  final mulukhiya = ref.watch(currentMulukhiyaProvider);
  return mulukhiya?.postLabel ?? '投稿';
});

/// The label to use for "boost/renote" actions (e.g. "リキュア" on precure.fun).
final reblogLabelProvider = Provider<String>((ref) {
  final mulukhiya = ref.watch(currentMulukhiyaProvider);
  if (mulukhiya?.reblogLabel != null) return mulukhiya!.reblogLabel!;
  final adapter = ref.watch(currentAdapterProvider);
  return adapter is ReactionSupport ? 'リノート' : 'ブースト';
});

/// The label to use for "favourite/reaction" actions.
final favouriteLabelProvider = Provider<String>((ref) {
  final adapter = ref.watch(currentAdapterProvider);
  return adapter is ReactionSupport ? 'リアクション' : 'お気に入り';
});

/// Maximum post content length from mulukhiya, falling back to adapter default.
final maxPostLengthProvider = Provider<int?>((ref) {
  final mulukhiya = ref.watch(currentMulukhiyaProvider);
  final adapter = ref.watch(currentAdapterProvider);
  return mulukhiya?.maxPostLength ?? adapter?.capabilities.maxPostContentLength;
});

/// Theme seed color: user override > mulukhiya > default green.
final themeSeedColorProvider = Provider<Color>((ref) {
  final account = ref.watch(currentAccountProvider);
  if (account != null) {
    final custom = ref.watch(
      accountThemeColorProvider(account.key.toStorageKey()),
    );
    if (custom != null) return custom;
  }

  final mulukhiya = ref.watch(currentMulukhiyaProvider);
  final hex = mulukhiya?.themeColorHex;
  if (hex != null && hex.startsWith('#') && hex.length >= 7) {
    try {
      final colorValue = int.parse(hex.substring(1, 7), radix: 16);
      return Color(0xFF000000 | colorValue);
    } catch (_) {}
  }
  return Colors.green;
});

/// URL of the :sabacan: custom emoji on the current server (null if unavailable).
///
/// ⚠ **自前で `getEmojis()` を叩かず [customEmojisProvider] から導出する** (#988)。
/// 以前は同じ一覧をもう一度取りに行っており、(1) 全件取得が二重に走る
/// (2) 失敗を `catch (_) { return null; }` で握るので、あちらの自動再取得
/// (#988) の恩恵を受けられず固着する、の 2 つの問題があった。
///
/// consumer は `.valueOrNull` で読んでいるので、失敗時に AsyncError が伝播しても
/// 従来どおり null として扱われる（表示は出ない）。
final sabacanUrlProvider = FutureProvider<String?>((ref) async {
  final emojis = await ref.watch(customEmojisProvider.future);
  return emojis.where((e) => e.shortcode == 'sabacan').firstOrNull?.url;
});

/// カスタム絵文字の取得が一過性の失敗で落ちたときの、自動再取得の刻み (#988)。
///
/// **有限にするのが眼目。** 無制限に粘ると、本当に圏外のときへ probe を撃ち
/// 続けることになる。ここで拾いきれなかった分は
/// [retryCustomEmojisIfFailed]（フォアグラウンド復帰）が受け持つ。
const kCustomEmojiRetryDelays = [
  Duration(milliseconds: 500),
  Duration(seconds: 2),
  Duration(seconds: 5),
];

/// 絵文字取得の失敗を、この場で再取得する価値があるかで分ける (#988)。
///
/// ⚠ **timeout は対象にしない。** `receiveTimeout` は 60 秒（`network_timeouts`）
/// なので、含めると「TCP は受けるが `/api/v1/custom_emojis` を返さない」サーバー
/// で **60 秒 × 4 回 ＝ 約 4 分**、provider が AsyncLoading のままになる。その間
/// [flash_view_screen] は開始ゲートも再試行導線も出さないので、**Play が 4 分
/// スピナーのまま何も操作できない**（従来は約 1 分でエラー面に到達していた）。
/// 重い全件 GET を 4 回投げる点も悪い。
///
/// 判断の軸は [isImmediateConnectFailure] と揃える — **既に時間を使った失敗は
/// 待ち直しても得が無い**。5xx は即座に返るうえサーバー再構築中に復帰しうるので
/// 対象に残す。
bool shouldRetryEmojiFetch(Object error) {
  if (classifyRestoreFailure(error) != RestoreOutcome.retriable) return false;
  if (error is DioException) {
    const timeouts = {
      DioExceptionType.connectionTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.sendTimeout,
    };
    return !timeouts.contains(error.type);
  }
  return true;
}

/// 現在アカウントのサーバーが提供するカスタム絵文字一覧。アカウント切替で
/// 自動再 fetch される。常時 mount される SimplePostBar 等から繰り返し参照
/// される想定でキャッシュ目的に分離（emoji_picker は state 変数で都度 fetch
/// しているが、別 issue でこちらに寄せる余地あり）。
///
/// ## 一過性の失敗を抱え込まない (#988)
///
/// この provider は素の [FutureProvider] なので、**一度 AsyncError になると
/// その状態を保持し続ける**。再評価の契機は [currentAdapterProvider] の変化
/// （＝アカウント切替）しか無く、回線が戻っても絵文字は戻らなかった。
///
/// 2026-08-18 のユーザー報告（毎朝の起動で絵文字が読めない）がこの形で、
/// 「しばらくすると復活する」の正体は **オフライン保持していた別アカウントが
/// 復元されて adapter が差し替わったタイミング**だった。つまり絵文字の復帰が
/// 無関係なアカウント復元の完了に相乗りしていた。
///
/// 直すのは「保持し続ける」側であって、`const []` を返さず rethrow する方では
/// ない（後述の #609 のとおり、そちらは正しい）。
final customEmojisProvider = FutureProvider<List<CustomEmoji>>((ref) async {
  final adapter = ref.watch(currentAdapterProvider);
  if (adapter is! CustomEmojiSupport) return const [];
  final support = adapter as CustomEmojiSupport;
  // アカウント切替でこの provider が捨てられたら、待ち時間の途中でも降りる。
  // ⚠ これが無いと、**もう使っていないアダプタの失敗が Sentry に載る** —
  // 切替後も古いループが最大 7.5 秒 `getEmojis()` を撃ち続け、最後に
  // captureException まで到達していた。#988 の効きを測る当の信号が濁る。
  var disposed = false;
  ref.onDispose(() => disposed = true);
  // 終了は return / rethrow のみ。上限は下の `attempt <` 側が持つ（ここに条件を
  // 書くと、解析器が「正常終了しうる」と見て非 null 戻り値を証明できない）。
  for (var attempt = 0; ; attempt++) {
    try {
      return await support.getEmojis();
    } catch (e, st) {
      // 一過性（接続断 / 5xx）なら、少し待ってもう一度取りに行く。恒久失敗
      // （4xx 等）と timeout は対象外（[shouldRetryEmojiFetch] の doc を参照）。
      if (attempt < kCustomEmojiRetryDelays.length &&
          shouldRetryEmojiFetch(e)) {
        // ⚠ 生の例外を埋めない。release では debugPrint が丸ごと breadcrumb に
        // なり、`_scrubBreadcrumb` は data しか見ないので message は素通しになる。
        // `DioException.toString()` の uri に載る host は、tag では
        // `isSensitiveTagKey` で弾いている値。
        debugLogException(
          'getEmojis failed (attempt ${attempt + 1}), retrying in '
          '${kCustomEmojiRetryDelays[attempt].inMilliseconds}ms',
          e,
        );
        await Future<void>.delayed(kCustomEmojiRetryDelays[attempt]);
        if (disposed) rethrow;
        continue;
      }
      // 失敗時に `const []` を返すと consumer (shortcode 警告) からは
      // 「本当に空」と区別できず、すべての `:foo:` を unknown 扱いで赤波下線
      // 化してしまう (#609 false positive)。AsyncError として伝播させて
      // consumer の `valueOrNull == null` 判定で警告抑制経路に揃える。
      debugLogException('getEmojis failed', e);
      Sentry.captureException(e, stackTrace: st);
      rethrow;
    }
  }
});

/// カスタム絵文字が失敗状態で止まっていたら取り直す (#988)。
///
/// [kCustomEmojiRetryDelays] を使い切っても戻らなかった場合（回線が数十秒以上
/// 落ちていた等）の受け皿。フォアグラウンド復帰から呼ぶ。
///
/// ⚠ **成功しているときに呼んでも取り直さない。** 復帰のたびに全サーバーの
/// 絵文字一覧（数千件になることがある）を取り直すのは重すぎる。アカウント切替
/// による通常の再 fetch とも二重になる。
///
/// ⚠ **再取得中に呼んでも重ねない。** `hasError` だけで判定すると多重起動する。
/// riverpod は `ref.invalidate` 由来の再構築を seamless に扱い、
/// `AsyncLoading.copyWithPrevious(isRefresh: true)` が **`AsyncError(isLoading:
/// true)` を返す**ため、`hasError` は再取得が決着するまで true のままになる
/// （riverpod 2.6.1 で実測）。ガードが無いと復帰のたびにループが増え、次の順序で
/// **成功したのに失敗したように見える**:
///
/// 1. 復帰 → ループ B 開始
/// 2. 1 秒後にもう一度復帰 → `hasError` はまだ true → ループ C 開始
/// 3. riverpod はループ B を「用済み」にするが、Dart の async 関数自体は止まらない
/// 4. **ループ B が成功する → 破棄される**
/// 5. ループ C が力尽きて AsyncError → 画面は失敗のまま
///
/// 同じ lifecycle ハンドラの数行上にある [AccountManagerNotifier.refreshOfflineRestoresOnResume]
/// も、内部で多重起動を潰している（`_offlineRetryLoopRunning` / `_manualRetryRunning`）。
/// 揃える。
void retryCustomEmojisIfFailed(WidgetRef ref) {
  final snapshot = ref.read(customEmojisProvider);
  if (snapshot.hasError && !snapshot.isLoading) {
    ref.invalidate(customEmojisProvider);
  }
}

/// Local timeline display name: use default hashtag if available.
final localTimelineNameProvider = Provider<String>((ref) {
  final mulukhiya = ref.watch(currentMulukhiyaProvider);
  final tag = mulukhiya?.defaultHashtag;
  return tag != null ? '#$tag' : 'ローカル';
});

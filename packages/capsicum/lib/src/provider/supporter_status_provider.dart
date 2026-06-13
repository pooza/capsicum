import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../model/account.dart';
import '../service/push_relay_client.dart';
import '../service/supporter_status_store.dart';
import 'account_manager_provider.dart';

/// サポーター状態の保持先 (#428 D 抽象層)。
///
/// ローカルの正本は [LocalSupporterStatusStore]。#596 (B-4) でサーバー側保持
/// (capsicum-relay) が加わったが、relay はあくまで端末間同期のハブで、
/// ローカル store がオフライン時のフォールバックとして残る。テストでは
/// fake 実装を override できる。
final supporterStatusStoreProvider = Provider<SupporterStatusStore>(
  (ref) => LocalSupporterStatusStore(),
);

/// サーバー同期 (#596) に使う relay クライアント。テストで fake に
/// 差し替えるための注入点。
final supporterRelayClientProvider = Provider<PushRelayClient>(
  (_) => PushRelayClient(),
);

/// サポーター（投げ銭）状態 (#428)。
///
/// 商品タイプ（消耗型 / 将来のサブスク）と保持先（ローカル + サーバー同期
/// #596）をこの抽象の内側に隠す。UI は本 provider（特に
/// [isSupporterProvider]）だけを参照し、課金実装を直接は触らない。
/// アプリ寿命で保持するため autoDispose しない（バッジは全画面で参照）。
///
/// サーバー同期 (#596 / capsicum-relay#18) の方針:
///
/// - 投げ銭は人（端末）単位の購入だが、サーバー側保持は account-keyed
///   （`username@host`）。投げ銭時点のログイン中**全アカウント**に記録し、
///   取得時はいずれかのアカウントがサポーターならバッジを出す。これで
///   「スマホで投げ銭 → デスクトップ（同じアカウントでログイン）にも
///   バッジ」が成立する
/// - relay 不通時はローカル値で動き、次回起動 / アカウント変化時に再同期
///   （装飾バッジ用途なので取りこぼしより静かな degrade を優先）
/// - `tip_count` はサーバー側で端末間合算される近似値。バッジ判定は
///   `first_tipped_at` の有無のみで行うため、再送による過大計上は許容
class SupporterStatusNotifier extends AsyncNotifier<SupporterRecord> {
  SupporterStatusStore get _store => ref.read(supporterStatusStoreProvider);
  PushRelayClient get _relay => ref.read(supporterRelayClientProvider);

  bool _syncing = false;

  /// 同期実行中に新たな同期要求（ログイン追加等）が来たことを示す。
  /// 現在の往復が終わったらもう一周する (#701)。
  bool _resyncRequested = false;

  /// サーバー同期を済ませたアカウント（relay account key = `username@host`）。
  /// ログイン追加で未処理のキーが現れたら再同期し、同期済みサポーターでも
  /// 新アカウントにはサーバー側レコードをバックフィルする (#699)。件数では
  /// なくキー集合で持つことで、同数のアカウント入れ替え（A 削除 + B 追加）も
  /// 取りこぼさない。
  final Set<String> _syncedAccountKeys = {};

  @override
  Future<SupporterRecord> build() {
    // アカウントが揃った時点（起動直後の復元完了・ログイン追加）で
    // サーバー同期を走らせる。listener は notifier と同寿命。
    ref.listen<AccountManagerState>(accountManagerProvider, (prev, next) {
      final hasUnsyncedAccount = next.accounts.any(
        (a) => !_syncedAccountKeys.contains(_relayAccount(a)),
      );
      if (hasUnsyncedAccount) {
        unawaited(_syncWithServer());
      }
    }, fireImmediately: true);
    return _store.load();
  }

  /// 投げ銭が成立した時に購入フロー（段 2）から呼ぶ。
  ///
  /// B-3: 一度でも投げ銭すれば生涯サポーター。[SupporterRecord.firstTippedAt]
  /// は初回のみ設定し以降不変。消耗型のため複数回呼ばれうるので
  /// [SupporterRecord.tipCount] を加算し、直近 SKU を記録する。
  /// ローカル保存の成立後、サーバーへの反映 (#596) は fire-and-forget で
  /// 行う（失敗してもローカルのバッジは成立しており、未同期レコードは
  /// 次回起動の [_syncWithServer] が汲み上げる）。
  Future<void> markTipped({required String sku}) async {
    final current = state.valueOrNull ?? SupporterRecord.empty;
    final updated = current.copyWith(
      firstTippedAt: current.firstTippedAt ?? DateTime.now(),
      tipCount: current.tipCount + 1,
      lastSku: sku,
    );
    await _store.save(updated);
    state = AsyncData(updated);
    unawaited(_uploadToServer(sku: sku));
  }

  /// 起動時・アカウント変化時のサーバー同期 (#596)。
  ///
  /// - ローカルが非サポーター: 各アカウントをサーバーに照会し、どれかに
  ///   レコードがあれば採用（他端末で投げ銭済みのケース）
  /// - ローカルがサポーターで未同期: 全量をバックフィル
  ///   （v1.27〜のローカル先行レコードの汲み上げ）
  Future<void> _syncWithServer() async {
    // 同期実行中に再要求が来たら（A 同期の往復中に B をログイン追加した等）、
    // その場では弾いて予約だけ立て、現在の往復が終わってからもう一周する
    // (#701)。単に return すると増えた分のアカウントが次のアカウント数変化
    // まで（実質アプリ再起動まで）同期されず、#596 バックフィルが新アカウント
    // で成立しなくなる。
    if (_syncing) {
      _resyncRequested = true;
      return;
    }
    _syncing = true;
    try {
      do {
        // 周回の先頭でクリアし、この往復中に来た再要求だけを次周に持ち越す。
        _resyncRequested = false;
        final accounts = ref.read(accountManagerProvider).accounts;
        if (accounts.isEmpty) break;
        final record = state.valueOrNull ?? await _store.load();
        if (!record.isSupporter) {
          await _adoptFromServer(record, accounts);
        } else {
          // 同期済み (syncedToServer == true) でも、ログイン追加で増えた
          // アカウントにはサーバー側レコードが無い。スキップせず upload して
          // 新アカウントへバックフィルする (#699)。listener が未処理キーの
          // 出現時のみ発火するため、既存アカウントへの再送（過大計上・許容）
          // は最小限に留まる。
          await _uploadToServer(sku: record.lastSku);
        }
        _syncedAccountKeys
          ..clear()
          ..addAll(accounts.map(_relayAccount));
      } while (_resyncRequested);
    } catch (e) {
      // relay 不通・オフラインは正常系の degrade。次の機会に再同期する。
      // （_syncedAccountKeys は更新しないので、次のアカウント変化で再発火する）
      _breadcrumb('sync failed: ${e.runtimeType}');
      debugPrint('capsicum: supporter.sync: failed (${e.runtimeType})');
    } finally {
      _syncing = false;
    }
  }

  /// いずれかのアカウントのサーバー側レコードを探し、見つかれば採用する。
  Future<void> _adoptFromServer(
    SupporterRecord record,
    List<Account> accounts,
  ) async {
    for (final account in accounts) {
      final remote = await _relay.fetchSupporterStatus(
        account: _relayAccount(account),
        server: account.key.host,
      );
      final firstTippedAt = _parseRelayTime(remote?['first_tipped_at']);
      if (firstTippedAt == null) continue;
      final adopted = record.copyWith(
        firstTippedAt: firstTippedAt,
        syncedToServer: true,
      );
      await _store.save(adopted);
      state = AsyncData(adopted);
      _breadcrumb('adopted from server');
      return;
    }
  }

  /// ローカルの投げ銭をサーバーへ反映する。
  ///
  /// - 同期済みレコード: 今回 1 回ぶんの増分（count=1）
  /// - 未同期レコード: 全量バックフィル（count=tipCount,
  ///   tipped_at=firstTippedAt）。全アカウント成功で syncedToServer=true
  ///
  /// 増分送信の失敗はサーバー側 tip_count の過少、バックフィル再試行は
  /// 過大計上になりうるが、いずれも近似値として許容（バッジ判定に影響
  /// しない。クラス docs 参照）。
  Future<void> _uploadToServer({String? sku}) async {
    final accounts = ref.read(accountManagerProvider).accounts;
    if (accounts.isEmpty) return;
    final record = state.valueOrNull ?? await _store.load();
    final firstTippedAt = record.firstTippedAt;
    if (firstTippedAt == null) return; // 非サポーターから呼ばれることはない想定
    try {
      for (final account in accounts) {
        if (record.syncedToServer) {
          await _relay.recordSupporterTip(
            account: _relayAccount(account),
            server: account.key.host,
            sku: sku,
          );
        } else {
          await _relay.recordSupporterTip(
            account: _relayAccount(account),
            server: account.key.host,
            sku: sku ?? record.lastSku,
            tippedAt: firstTippedAt,
            count: max(record.tipCount, 1),
          );
        }
      }
      if (!record.syncedToServer) {
        // バックフィルの await 中にアカウントが増えていたら（#701 backfill
        // 経路の race）、ここで synced を確定させると、増えた分のアカウントが
        // 以降の同期で `record.syncedToServer == true` の枝に落ちて二度と
        // バックフィルされない。synced 確定を見送って再同期を予約し、
        // 再周回で増えたアカウントにも行き渡らせる。既存アカウントへの
        // 再送は過大計上になるが近似値として許容（クラス docs 参照）。
        final accountsNow = ref.read(accountManagerProvider).accounts;
        if (accountsNow.length != accounts.length) {
          _resyncRequested = true;
          return;
        }
        final synced = (state.valueOrNull ?? record).copyWith(
          syncedToServer: true,
        );
        await _store.save(synced);
        state = AsyncData(synced);
      }
    } catch (e) {
      _breadcrumb('upload failed: ${e.runtimeType}');
      debugPrint('capsicum: supporter.sync: upload failed (${e.runtimeType})');
    }
  }

  /// relay / NSE と同じ account 表現（push 登録と同一キー空間）。
  static String _relayAccount(Account account) =>
      '${account.key.username}@${account.key.host}';

  /// relay (SQLite) の `YYYY-MM-DD HH:MM:SS` (UTC) を DateTime に変換する。
  /// `DateTime.parse` は素のスペース区切りをローカル時刻と解釈するため、
  /// UTC マーカーを補ってからパースする。
  static DateTime? _parseRelayTime(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse('${raw.replaceFirst(' ', 'T')}Z')?.toLocal();
  }

  static void _breadcrumb(String message) {
    try {
      Sentry.addBreadcrumb(
        Breadcrumb(
          category: 'supporter.sync',
          level: SentryLevel.info,
          message: message,
        ),
      );
    } catch (_) {
      // Sentry 未初期化等で本筋を止めない。
    }
  }
}

final supporterStatusProvider =
    AsyncNotifierProvider<SupporterStatusNotifier, SupporterRecord>(
      SupporterStatusNotifier.new,
    );

/// 生涯サポーターか（B-3）。バッジ UI（段 4）はこの bool だけを見る。
/// 読み込み中・エラー時は false にフォールバック（バッジ非表示が安全側）。
final isSupporterProvider = Provider<bool>(
  (ref) => ref.watch(supporterStatusProvider).valueOrNull?.isSupporter ?? false,
);

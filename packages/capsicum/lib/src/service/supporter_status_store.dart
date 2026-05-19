import 'package:shared_preferences/shared_preferences.dart';

/// サポーター（投げ銭）状態の永続レコード (#428)。
///
/// B-3 確定: 一度でも投げ銭すれば生涯サポーターバッジ。よって
/// 「サポーターか否か」は [firstTippedAt] の有無で決まる単調な状態。
///
/// B-4 確定: 最終的にはサーバー側保持が希望だが、v1.27 は端末ローカルで
/// 開始し後日サーバーへ汲み上げる段階導入。本レコードは将来サーバーへ
/// 汲み上げるのに足る最小情報（初回投げ銭時刻・回数・直近 SKU）を持ち、
/// [syncedToServer] を移行フックとして残す（v1.27 では常に false。
/// サーバー同期実装時に「未同期レコードを汲み上げる」判定に使う）。
class SupporterRecord {
  /// 初回投げ銭時刻。null ならまだ一度も投げ銭していない。
  /// 生涯バッジのため、一度設定したら以降変更しない。
  final DateTime? firstTippedAt;

  /// 投げ銭した通算回数。再投げ銭（消耗型のため複数回可）で増える。
  /// UI には出さないが、将来のサーバー汲み上げ・分析のために保持する。
  final int tipCount;

  /// 直近に投げ銭した SKU（`supporter.tip.small` 等）。将来のサーバー
  /// 汲み上げ・分析用。UI には出さない。
  final String? lastSku;

  /// サーバー側へ汲み上げ済みか。v1.27 では常に false。サーバー同期を
  /// 実装した時点で「未同期のローカルレコードを汲み上げる」ための移行
  /// フック（B-4 段階導入）。
  final bool syncedToServer;

  const SupporterRecord({
    this.firstTippedAt,
    this.tipCount = 0,
    this.lastSku,
    this.syncedToServer = false,
  });

  /// まだ一度も投げ銭していない初期状態。
  static const empty = SupporterRecord();

  /// 生涯サポーターか（B-3）。UI（バッジ）はこの値だけを見る。
  bool get isSupporter => firstTippedAt != null;

  SupporterRecord copyWith({
    DateTime? firstTippedAt,
    int? tipCount,
    String? lastSku,
    bool? syncedToServer,
  }) => SupporterRecord(
    firstTippedAt: firstTippedAt ?? this.firstTippedAt,
    tipCount: tipCount ?? this.tipCount,
    lastSku: lastSku ?? this.lastSku,
    syncedToServer: syncedToServer ?? this.syncedToServer,
  );
}

/// サポーター状態の保持先を抽象化する (#428 D 抽象層)。
///
/// v1.27 は [LocalSupporterStatusStore]（端末ローカル）のみ。将来サーバー
/// 側保持に移行する際は本インターフェースのサーバー実装を差し込み、UI /
/// provider 側は一切変更しない。商品タイプ（消耗型 / 将来のサブスク）も
/// 保持先もこのインターフェースの内側に閉じる。
abstract class SupporterStatusStore {
  /// 現在のレコードを読み出す。未投げ銭なら [SupporterRecord.empty] 相当。
  Future<SupporterRecord> load();

  /// レコードを永続化する。
  Future<void> save(SupporterRecord record);
}

/// 端末ローカル（`SharedPreferencesAsync`）の保持実装 (#428 v1.27)。
///
/// 消耗型 IAP はストアの購入復元の対象外（再インストール・複数端末で
/// レシートが戻らない）。よってレシート復元に依存せず、購入成功時に立てた
/// フラグをローカルに永続化する。再インストールで消える制約は B-4 の
/// 段階導入方針として割り切り、恒久化はサーバー側保持で対応する。
class LocalSupporterStatusStore implements SupporterStatusStore {
  static const _keyFirstTippedAtMs = 'capsicum_supporter_first_tipped_at_ms';
  static const _keyTipCount = 'capsicum_supporter_tip_count';
  static const _keyLastSku = 'capsicum_supporter_last_sku';
  static const _keySyncedToServer = 'capsicum_supporter_synced_to_server';

  // App Group 共有は不要（NSE / バックグラウンド isolate と共有しない）。
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  @override
  Future<SupporterRecord> load() async {
    final atMs = await _prefs.getInt(_keyFirstTippedAtMs);
    return SupporterRecord(
      firstTippedAt: atMs != null
          ? DateTime.fromMillisecondsSinceEpoch(atMs)
          : null,
      tipCount: await _prefs.getInt(_keyTipCount) ?? 0,
      lastSku: await _prefs.getString(_keyLastSku),
      syncedToServer: await _prefs.getBool(_keySyncedToServer) ?? false,
    );
  }

  @override
  Future<void> save(SupporterRecord record) async {
    final at = record.firstTippedAt;
    if (at != null) {
      await _prefs.setInt(_keyFirstTippedAtMs, at.millisecondsSinceEpoch);
    } else {
      await _prefs.remove(_keyFirstTippedAtMs);
    }
    await _prefs.setInt(_keyTipCount, record.tipCount);
    final sku = record.lastSku;
    if (sku != null) {
      await _prefs.setString(_keyLastSku, sku);
    } else {
      await _prefs.remove(_keyLastSku);
    }
    await _prefs.setBool(_keySyncedToServer, record.syncedToServer);
  }
}

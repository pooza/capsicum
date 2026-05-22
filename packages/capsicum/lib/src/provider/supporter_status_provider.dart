import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../service/supporter_status_store.dart';

/// サポーター状態の保持先 (#428 D 抽象層)。
///
/// v1.27 は [LocalSupporterStatusStore]。サーバー側保持へ移行する際は
/// この provider を override するだけで、[supporterStatusProvider] 以下と
/// UI は無変更で差し替わる。テストでも fake 実装を override できる。
final supporterStatusStoreProvider = Provider<SupporterStatusStore>(
  (ref) => LocalSupporterStatusStore(),
);

/// サポーター（投げ銭）状態 (#428)。
///
/// 商品タイプ（消耗型 / 将来のサブスク）と保持先（ローカル / 将来の
/// サーバー）をこの抽象の内側に隠す。UI は本 provider（特に
/// [isSupporterProvider]）だけを参照し、課金実装を直接は触らない。
/// アプリ寿命で保持するため autoDispose しない（バッジは全画面で参照）。
class SupporterStatusNotifier extends AsyncNotifier<SupporterRecord> {
  SupporterStatusStore get _store => ref.read(supporterStatusStoreProvider);

  @override
  Future<SupporterRecord> build() => _store.load();

  /// 投げ銭が成立した時に購入フロー（段 2）から呼ぶ。
  ///
  /// B-3: 一度でも投げ銭すれば生涯サポーター。[SupporterRecord.firstTippedAt]
  /// は初回のみ設定し以降不変。消耗型のため複数回呼ばれうるので
  /// [SupporterRecord.tipCount] を加算し、直近 SKU を記録する。
  Future<void> markTipped({required String sku}) async {
    final current = state.valueOrNull ?? SupporterRecord.empty;
    final updated = current.copyWith(
      firstTippedAt: current.firstTippedAt ?? DateTime.now(),
      tipCount: current.tipCount + 1,
      lastSku: sku,
    );
    await _store.save(updated);
    state = AsyncData(updated);
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

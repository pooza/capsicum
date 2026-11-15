import 'dart:async';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../provider/account_manager_provider.dart';
import '../../service/annict_draft_store.dart';

/// Annict の感想・記録の画面の自動保存 (#1382)。
///
/// 開いたら同じ作品・話数の下書きを戻し、入力のたびに少し待って保存する。
/// 投稿に成功したら [clearAnnictDraft] で消す。閉じるときは待っている保存を
/// その場で書く。
///
/// ⚠ **戻す前に打ち始めていたら戻さない**（読み込みは非同期なので、開いてすぐ
/// 打った本文を下書きで上書きしない）。
///
/// ⚠ アカウントは**開いたときのもの**で固定する（デッキのカラムから開いた
/// ときはそのカラムのアカウント。途中で現在のアカウントが替わっても、別の
/// アカウントの枠へ書かない）。
mixin AnnictDraftAutoSave<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  TextEditingController get draftBodyController;
  AnnictDraftKind get draftKind;
  int get draftId;

  /// 今の評価（軸の名前 → 評価・未選択の軸は入れない）。
  Map<String, AnnictRatingState> currentDraftRatings();

  /// 戻した評価を画面へ当てる（setState の中で呼ばれる）。
  void applyDraftRatings(Map<String, AnnictRatingState> ratings);

  static const saveDelay = Duration(milliseconds: 500);

  AnnictDraftStore? _draftStore;
  Timer? _draftTimer;
  bool _draftTouched = false;
  bool _draftApplying = false;

  /// 保存の仕組みを作る。テストで読み込みの遅れを作るための差し替え口。
  @visibleForTesting
  AnnictDraftStore createAnnictDraftStore(String accountKey) =>
      AnnictDraftStore(accountKey: accountKey, kind: draftKind, id: draftId);

  /// [State.initState] から呼ぶ。
  void initAnnictDraft() {
    final account = ref.read(currentAccountProvider);
    if (account == null) return;
    final store = createAnnictDraftStore(account.key.toStorageKey());
    _draftStore = store;
    draftBodyController.addListener(_onDraftBodyChanged);
    unawaited(
      store.load().then((draft) {
        if (!mounted || draft == null || _draftTouched) return;
        _draftApplying = true;
        setState(() {
          draftBodyController.text = draft.body;
          applyDraftRatings(draft.ratings);
        });
        _draftApplying = false;
      }),
    );
  }

  void _onDraftBodyChanged() {
    if (_draftApplying) return;
    _draftTouched = true;
    _scheduleAnnictDraftSave();
  }

  /// 評価を変えたときに呼ぶ。
  void onAnnictDraftRatingChanged() {
    _draftTouched = true;
    _scheduleAnnictDraftSave();
  }

  void _scheduleAnnictDraftSave() {
    _draftTimer?.cancel();
    _draftTimer = Timer(saveDelay, _flushAnnictDraft);
  }

  void _flushAnnictDraft() {
    final store = _draftStore;
    if (store == null) return;
    unawaited(
      store.save(
        AnnictDraft(
          body: draftBodyController.text,
          ratings: currentDraftRatings(),
        ),
      ),
    );
  }

  /// 投稿に成功したら呼ぶ。
  Future<void> clearAnnictDraft() async {
    _draftTimer?.cancel();
    await _draftStore?.clear();
  }

  /// [State.dispose] から、コントローラを捨てる**前に**呼ぶ。
  void disposeAnnictDraft() {
    final pending = _draftTimer?.isActive ?? false;
    _draftTimer?.cancel();
    if (pending) _flushAnnictDraft();
    draftBodyController.removeListener(_onDraftBodyChanged);
  }
}

/// 本文の欄の下に出す案内 (#1382)。
const annictDraftNote = '入力は自動で保存されます（投稿すると消えます）';

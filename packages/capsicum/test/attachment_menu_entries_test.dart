import 'package:capsicum/src/ui/screen/compose_screen.dart';
import 'package:capsicum/src/ui/widget/desktop_menu_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// #941: 投稿画面のデスクトップメニューが出す、添付 1 件ぶんの項目。
///
/// 眼目は #835 の「**出し分けの条件は画面のシート / メニュー側と同一にする。
/// 使えない操作をメニューにだけ見せない**」。`_showAttachmentMenu`（サムネタップの
/// シート）は動画・音声・ドライブファイルでは編集系を出さないので、メニュー側も
/// 同じ条件で押せなくなっている必要がある。
void main() {
  AttachmentMenuCallbacks callbacks(List<String> log) =>
      AttachmentMenuCallbacks(
        preview: () => log.add('preview'),
        crop: () => log.add('crop'),
        addOverlay: () => log.add('overlay'),
        editDescription: () => log.add('description'),
      );

  List<MenuEntry> build({
    bool previewable = true,
    bool croppable = true,
    bool busy = false,
    List<String>? log,
  }) => buildAttachmentMenuEntries(
    previewable: previewable,
    croppable: croppable,
    busy: busy,
    callbacks: callbacks(log ?? []),
  );

  MenuActionEntry action(List<MenuEntry> entries, String label) =>
      entries.whereType<MenuActionEntry>().firstWhere((e) => e.label == label);

  test('項目はシートと同じ 4 つ・同じ並び', () {
    expect(build().whereType<MenuActionEntry>().map((e) => e.label), [
      '拡大して確認…',
      'トリミング・回転…',
      '文字・スタンプを入れる…',
      '説明 (ALT)…',
    ]);
  });

  /// シートは条件に合わない項目を隠すが、メニューは無効化して残す（#912 / #939 と
  /// 揃える）。**項目数は状態によらず 4 のまま**であることをここで固定する。
  test('どの状態でも項目は消えず 4 つのまま', () {
    for (final previewable in [true, false]) {
      for (final croppable in [true, false]) {
        expect(build(previewable: previewable, croppable: croppable).length, 4);
      }
    }
  });

  test('ローカル静止画（プレビュー可・トリミング可）は全項目が有効', () {
    final entries = build();

    for (final label in ['拡大して確認…', 'トリミング・回転…', '文字・スタンプを入れる…', '説明 (ALT)…']) {
      expect(action(entries, label).onSelected, isNotNull, reason: label);
    }
  });

  /// ドライブ上の画像。原寸 URL があるのでプレビューはできるが、差し替えられない
  /// ので編集は不可（`_isCroppableImage` が isDrive を弾く）。
  test('ドライブ画像はプレビューだけ有効', () {
    final entries = build(previewable: true, croppable: false);

    expect(action(entries, '拡大して確認…').onSelected, isNotNull);
    expect(action(entries, 'トリミング・回転…').onSelected, isNull);
    expect(action(entries, '文字・スタンプを入れる…').onSelected, isNull);
  });

  /// 動画 / 音声。`_attachmentImageProvider` が null を返すのでプレビューも不可。
  test('動画・音声は説明 (ALT) だけ有効', () {
    final entries = build(previewable: false, croppable: false);

    expect(action(entries, '拡大して確認…').onSelected, isNull);
    expect(action(entries, 'トリミング・回転…').onSelected, isNull);
    expect(action(entries, '文字・スタンプを入れる…').onSelected, isNull);
    expect(action(entries, '説明 (ALT)…').onSelected, isNotNull);
  });

  test('説明 (ALT) は添付の種類によらず有効（シートと同じ）', () {
    for (final previewable in [true, false]) {
      for (final croppable in [true, false]) {
        expect(
          action(
            build(previewable: previewable, croppable: croppable),
            '説明 (ALT)…',
          ).onSelected,
          isNotNull,
        );
      }
    }
  });

  test('送信中は全項目が無効', () {
    final entries = build(busy: true);

    expect(
      entries.whereType<MenuActionEntry>().every((e) => e.onSelected == null),
      isTrue,
    );
  });

  test('各項目は対応するコールバックを呼ぶ', () {
    final log = <String>[];
    final entries = build(log: log);

    for (final label in ['拡大して確認…', 'トリミング・回転…', '文字・スタンプを入れる…', '説明 (ALT)…']) {
      action(entries, label).onSelected!();
    }

    expect(log, ['preview', 'crop', 'overlay', 'description']);
  });

  /// #835 の約束。添付ごとのコールバックは画面側が index をキーに一度だけ組んで
  /// 使い回す（`_callbacksForAttachment`）ので、**同じ束を渡せば値等価**になり、
  /// 本文を 1 文字打つたびにメニューバーが作り直されない。
  test('同じコールバック束で組み直せば値等価になる', () {
    final shared = callbacks([]);

    List<MenuEntry> make() => buildAttachmentMenuEntries(
      previewable: true,
      croppable: true,
      busy: false,
      callbacks: shared,
    );

    expect(sameMenuEntries(make(), make()), isTrue);
  });

  test('添付の種類が変われば値等価は崩れる（メニューが出し直される）', () {
    final shared = callbacks([]);

    List<MenuEntry> make({required bool croppable}) =>
        buildAttachmentMenuEntries(
          previewable: true,
          croppable: croppable,
          busy: false,
          callbacks: shared,
        );

    expect(
      sameMenuEntries(make(croppable: true), make(croppable: false)),
      isFalse,
    );
  });
}

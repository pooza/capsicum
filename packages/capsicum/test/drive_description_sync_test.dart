import 'package:capsicum/src/ui/util/drive_description_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1027-F1: 投稿画面で編集したドライブ添付の ALT が黙って捨てられていた。
///
/// 送信経路は `if (entry.isDrive) return entry.driveFile!.id;` で ID だけを
/// 返しており、ローカルからアップロードした添付（`AttachmentDraft` に載る）と
/// 違って `entry.description` を誰も見ていなかった。編集ダイアログは
/// drive / local を区別せず開くので、**ユーザーからは編集できたように見える**。
///
/// ⚠⚠ **ドライブのファイルは実体が 1 つ。**書き換えると、そのファイルを使って
/// いる**過去の投稿の ALT も変わる**。Misskey の Web UI と同じ挙動で、仕様と
/// して受け入れている（#1027 の判断）。だからこそ「変わったものだけ」を送る。
void main() {
  ({String fileId, String? original, String current}) entry(
    String fileId, {
    String? original,
    required String current,
  }) => (fileId: fileId, original: original, current: current);

  test('変わったものだけを返す', () {
    final pending = pendingDriveDescriptionUpdates([
      entry('a', original: '古い説明', current: '新しい説明'),
      entry('b', original: '触っていない', current: '触っていない'),
    ]);

    expect(pending, hasLength(1));
    expect(pending.single.fileId, 'a');
    expect(pending.single.description, '新しい説明');
  });

  // ⚠ Misskey は ALT 未設定のファイルで `comment` を返さない。空文字へ寄せて
  // 比べないと、**開いて閉じただけの添付が毎回「変更あり」になる**（＝触って
  // いない過去の投稿へ更新が波及する）。
  test('original が null と空文字は同じ「ALT なし」', () {
    expect(
      pendingDriveDescriptionUpdates([entry('a', current: '')]),
      isEmpty,
      reason: 'null → 空文字は変更ではない',
    );
    expect(
      pendingDriveDescriptionUpdates([entry('a', original: '', current: '')]),
      isEmpty,
    );
  });

  test('null から値を入れたら変更として返す', () {
    final pending = pendingDriveDescriptionUpdates([
      entry('a', current: '新しく付けた ALT'),
    ]);
    expect(pending.single.description, '新しく付けた ALT');
  });

  // ⚠ 空文字への変更は「消す」であって「変更なし」ではない。落とすと ALT を
  // 消せなくなる（#1005 と同型の取り違え）。
  test('空文字へ変えたら「消す」として返す', () {
    final pending = pendingDriveDescriptionUpdates([
      entry('a', original: '消したい説明', current: ''),
    ]);
    expect(pending.single.fileId, 'a');
    expect(pending.single.description, isEmpty);
  });

  test('ドライブ添付が無ければ空', () {
    expect(pendingDriveDescriptionUpdates([]), isEmpty);
  });

  test('複数の変更を順序どおり返す', () {
    final pending = pendingDriveDescriptionUpdates([
      entry('a', original: 'x', current: 'X'),
      entry('b', original: 'y', current: 'y'),
      entry('c', original: 'z', current: 'Z'),
    ]);
    expect(pending.map((p) => p.fileId), ['a', 'c']);
  });
}

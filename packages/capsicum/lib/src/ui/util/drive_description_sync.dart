/// 投稿の前にドライブ側へ書き戻すべき ALT を選ぶ (#1027-F1)。
///
/// ⚠ **「変わったものだけ」を返すのが要点。**毎回打つと、触っていない添付にまで
/// 書き込みが走る。ドライブのファイルは実体が 1 つで、**そのファイルを使って
/// いる過去の投稿の ALT も一緒に変わる**ため、無用な更新は波及範囲が広い。
///
/// ⚠ **`null` と空文字は同じ「ALT なし」。**Misskey は ALT 未設定のファイルで
/// `comment` を返さないので、比較の前に空文字へ寄せないと**開いて閉じただけの
/// 添付が毎回「変更あり」に見える**。
///
/// 空文字への変更（＝ALT を消す）は**含める**。「変更なし」ではない。
List<({String fileId, String description})> pendingDriveDescriptionUpdates(
  Iterable<({String fileId, String? original, String current})> entries,
) => [
  for (final e in entries)
    if (e.current != (e.original ?? ''))
      (fileId: e.fileId, description: e.current),
];

/// ソースを文字列で走査するガード群が共有する、ファイルの列挙 (#1168)。
///
/// ## なぜ共有するのか
///
/// ⚠⚠ **Windows では [File.path] の区切りが `\` になる。**ガードの除外リストや
/// 「綴りを持ってよい唯一の場所」の指定は `/` 区切りのリテラルで書いてあるので、
/// 素の `Directory(...).listSync()` を使うと**照合が外れ、許可されているはずの
/// ファイルが違反扱いになる**。2026-09-22 に Windows 機（x64・Flutter 3.44.6）で
/// **6 件が落ちた**のがこれで、CI（Linux）と macOS では緑だった。
///
/// ⚠ **逆向きの穴のほうが危ない。**「このファイルを必ず走査している」系の固定を
/// `/` 区切りで書いていると、Windows では**空振りしても気付けない**
/// （`expect(offenders, isEmpty)` は何も見ていなくても通る）。
///
/// そのため列挙はここへ寄せ、**返す [File] のパスは常に `/` 区切り**にする。
/// `File('lib/src/…')` は Windows でもそのまま開けるので、呼び出し側は返ってきた
/// パスをリテラルと直接比べてよい。
///
/// ⚠ **test 配下でこのヘルパーを迂回していないこと**は
/// `source_files_guard_test.dart` が見ている。
library;

import 'dart:io';

/// パス区切りを `/` へ正規化する。
///
/// ⚠ 区切りが混在した実測値（`lib/src/ui\util\fediverse_link.dart`）もあるので、
/// 「Windows なら」で分岐せず一律に置き換える。
String posixPath(String path) => path.replaceAll(r'\', '/');

/// [dir] 配下のファイルを、**`/` 区切りに正規化した**パスを持つ [File] として返す。
/// 並びはパス順（列挙順は OS 依存なので、失敗メッセージを安定させるため）。
///
/// - [extension] — この末尾を持つものだけ返す（`.dart` / `.md` / `_test.dart`）
/// - [recursive] — サブディレクトリを見るか。⚠ 既定は見る（#1061 で
///   `settings/` 配下の 8 画面が黙って検査対象から消えていた）
/// - [skipGenerated] — `.g.dart` / `.freezed.dart` を外すか
List<File> sourceFiles(
  String dir, {
  String extension = '.dart',
  bool recursive = true,
  bool skipGenerated = false,
}) {
  final out = <File>[
    for (final entity in Directory(dir).listSync(recursive: recursive))
      if (entity is File && posixPath(entity.path).endsWith(extension))
        if (!skipGenerated ||
            !(entity.path.endsWith('.g.dart') ||
                entity.path.endsWith('.freezed.dart')))
          File(posixPath(entity.path)),
  ];
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

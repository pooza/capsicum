import 'dart:io';

import 'package:capsicum_core/capsicum_core.dart';
import 'package:cross_file/cross_file.dart';
import 'package:dio/dio.dart';

import '../util/exception_scrub.dart';

/// ナウプレのアートワーク（ジャケット画像）として受け取る上限 (#1133)。
///
/// モロヘイヤが返すのは一辺 480px 程度（数十 KB）なので、これを超えるものは
/// ジャケットではない何かと見て捨てる。⚠ 縮小はしない（決定事項 3）。
const int kNowPlayingArtworkMaxBytes = 10 * 1024 * 1024;

/// 画像として受け取る MIME と、付ける拡張子。
const Map<String, String> _extensionByMime = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/gif': 'gif',
};

/// アートワークの代替テキスト (#1133)。
///
/// ⚠ **空にしない。**自動で足す添付なので、何も入れないと読み上げに何も出ない
/// 画像が投稿に付く。曲名もアーティストも無いときは、何の画像かだけ伝える。
String nowPlayingArtworkAlt(NowPlayingInfo info) {
  final parts = [
    for (final value in [info.title, info.artist])
      if (value != null && value.trim().isNotEmpty) value.trim(),
  ];
  return parts.isEmpty ? 'アルバムアートワーク' : '${parts.join(' / ')} のアルバムアートワーク';
}

/// [uri] のアートワークを取ってきて、添付に使えるファイルにする (#1133)。
/// 取れなければ null。
///
/// - `http` / `https`: 取得して [tempDir] へ書き出す（モロヘイヤの
///   `artwork_url`・MPRIS の `mpris:artUrl`）
/// - `file`: その場所の画像をそのまま使う（MPRIS がローカルのキャッシュを
///   指すことがある）
///
/// ⚠ **失敗はすべて null に倒す。**ジャケットは上積みで、取れなくても本文だけの
/// ナウプレとして投稿は成立する。
///
/// ⚠⚠ **画像でないものを添付にしない。**`file:` の行き先は再生中のプレイヤーが
/// 決めるので、拡張子で画像に限る（プレイヤーのメタデータ次第で任意のファイルが
/// 投稿に付く形にしない）。`http` は応答の Content-Type で見る。
Future<XFile?> fetchNowPlayingArtwork(
  Uri uri, {
  required Directory tempDir,
  Dio? dio,
}) async {
  try {
    return switch (uri.scheme) {
      'http' || 'https' => await _download(uri, tempDir, dio ?? _defaultDio()),
      'file' => await _local(uri),
      _ => null,
    };
  } catch (e) {
    debugLogException('nowplaying artwork fetch error', e);
    return null;
  }
}

Dio _defaultDio() => Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 10),
  ),
);

Future<XFile?> _download(Uri uri, Directory tempDir, Dio dio) async {
  final response = await dio.getUri<List<int>>(
    uri,
    options: Options(responseType: ResponseType.bytes),
  );
  final bytes = response.data;
  if (bytes == null || bytes.isEmpty) return null;
  if (bytes.length > kNowPlayingArtworkMaxBytes) return null;
  // `image/jpeg; charset=binary` のように引数が付くことがある。
  final mime = (response.headers.value(Headers.contentTypeHeader) ?? '')
      .split(';')
      .first
      .trim()
      .toLowerCase();
  final extension = _extensionByMime[mime];
  if (extension == null) return null;
  final name = 'nowplaying-artwork.$extension';
  // ⚠ **一意にするのはディレクトリの側。**`XFile.name` は IO ではパスの末尾から
  // 決まる（引数の `name` は使われない）ので、ファイル名に時刻を混ぜると、
  // それがそのまま投稿先のファイル名になる。
  final path =
      '${tempDir.path}/nowplaying_${DateTime.now().microsecondsSinceEpoch}/$name';
  final out = File(path);
  // macOS の一時ディレクトリは実体が未作成のことがあり、writeAsBytes は
  // 親ディレクトリを作らないため明示的に作成する。
  await out.create(recursive: true);
  await out.writeAsBytes(bytes, flush: true);
  return XFile(path, mimeType: mime, name: name);
}

Future<XFile?> _local(Uri uri) async {
  final path = uri.toFilePath();
  final dot = path.lastIndexOf('.');
  final extension = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  final mime = _extensionByMime.entries
      .where(
        (e) =>
            e.value == extension || (extension == 'jpeg' && e.value == 'jpg'),
      )
      .map((e) => e.key)
      .firstOrNull;
  if (mime == null) return null;
  final file = File(path);
  if (!await file.exists()) return null;
  final size = await file.length();
  if (size == 0 || size > kNowPlayingArtworkMaxBytes) return null;
  return XFile(path, mimeType: mime, name: 'nowplaying-artwork.$extension');
}

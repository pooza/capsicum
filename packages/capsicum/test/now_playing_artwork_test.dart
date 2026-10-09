import 'dart:io';
import 'dart:typed_data';

import 'package:capsicum/src/service/now_playing_artwork.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1133: ナウプレのアートワーク（ジャケット画像）を取ってきて添付にする。
///
/// ⚠ **失敗はすべて null。**ジャケットは上積みで、取れなくても本文だけの
/// ナウプレとして投稿は成立する。
class _Server implements HttpClientAdapter {
  _Server({
    this.status = 200,
    this.contentType = 'image/jpeg',
    List<int>? bytes,
  }) : bytes = bytes ?? const [0xFF, 0xD8, 0xFF, 0xE0];

  final int status;
  final String? contentType;
  final List<int> bytes;
  final List<Uri> requested = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri);
    return ResponseBody.fromBytes(
      bytes,
      status,
      headers: {
        if (contentType != null) Headers.contentTypeHeader: [contentType!],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('artwork_test'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  final uri = Uri.parse('https://example.com/a/480x480bb.jpg');

  Future<Object?> fetch(_Server server, {Uri? from}) => fetchNowPlayingArtwork(
    from ?? uri,
    tempDir: tempDir,
    dio: Dio()..httpClientAdapter = server,
  );

  group('http(s)', () {
    test('取得して一時ファイルに書き出す', () async {
      final server = _Server();

      final file = await fetchNowPlayingArtwork(
        uri,
        tempDir: tempDir,
        dio: Dio()..httpClientAdapter = server,
      );

      expect(server.requested, [uri]);
      expect(file, isNotNull);
      expect(file!.name, 'nowplaying-artwork.jpg');
      expect(file.mimeType, 'image/jpeg');
      expect(await File(file.path).readAsBytes(), server.bytes);
      expect(file.path, startsWith(tempDir.path));
    });

    test('拡張子は URL ではなく、応答の Content-Type で決める', () async {
      final file = await fetchNowPlayingArtwork(
        // 拡張子の無い URL（Spotify の画像がこの形）。
        Uri.parse('https://i.scdn.co/image/ab67616d0000b273'),
        tempDir: tempDir,
        dio: Dio()
          ..httpClientAdapter = _Server(
            contentType: 'image/png; charset=binary',
          ),
      );

      expect(file!.name, 'nowplaying-artwork.png');
      expect(file.mimeType, 'image/png');
    });

    test('⚠⚠ 画像でない応答は添付にしない', () async {
      for (final type in ['text/html', 'application/json', null]) {
        expect(
          await fetch(_Server(contentType: type)),
          isNull,
          reason: '$type',
        );
      }
    });

    test('失敗（404 / 500）は null', () async {
      expect(await fetch(_Server(status: 404)), isNull);
      expect(await fetch(_Server(status: 500)), isNull);
    });

    test('空の応答は null', () async {
      expect(await fetch(_Server(bytes: const [])), isNull);
    });

    test('⚠ 上限を超えるものは捨てる（縮小はしない・ジャケットではない何か）', () async {
      final huge = Uint8List(kNowPlayingArtworkMaxBytes + 1);
      expect(await fetch(_Server(bytes: huge)), isNull);
    });
  });

  group('file（MPRIS がローカルのキャッシュを指す）', () {
    test('画像ならそのまま使う', () async {
      final local = File('${tempDir.path}/cover.PNG')
        ..writeAsBytesSync(const [1, 2, 3]);

      final file = await fetchNowPlayingArtwork(
        Uri.file(local.path),
        tempDir: tempDir,
      );

      expect(file!.path, local.path);
      expect(file.mimeType, 'image/png');
    });

    test('⚠⚠ 画像の拡張子でなければ添付にしない（任意のファイルを投稿に付けない）', () async {
      final secret = File('${tempDir.path}/id_rsa')..writeAsStringSync('key');
      final text = File('${tempDir.path}/note.txt')..writeAsStringSync('x');

      for (final f in [secret, text]) {
        expect(
          await fetchNowPlayingArtwork(Uri.file(f.path), tempDir: tempDir),
          isNull,
          reason: f.path,
        );
      }
    });

    test('存在しない / 空のファイルは null', () async {
      expect(
        await fetchNowPlayingArtwork(
          Uri.file('${tempDir.path}/missing.jpg'),
          tempDir: tempDir,
        ),
        isNull,
      );
      final empty = File('${tempDir.path}/empty.jpg')..createSync();
      expect(
        await fetchNowPlayingArtwork(Uri.file(empty.path), tempDir: tempDir),
        isNull,
      );
    });
  });

  test('ほかのスキームは null', () async {
    expect(
      await fetchNowPlayingArtwork(
        Uri.parse('data:image/png;base64,AAAA'),
        tempDir: tempDir,
      ),
      isNull,
    );
  });

  group('代替テキスト', () {
    NowPlayingInfo info({String? title, String? artist}) =>
        NowPlayingInfo(sourceAppName: 'Music', title: title, artist: artist);

    test('曲名とアーティストから組む', () {
      expect(
        nowPlayingArtworkAlt(info(title: 'Song', artist: 'Artist')),
        'Song / Artist のアルバムアートワーク',
      );
    });

    test('片方だけでも組む', () {
      expect(nowPlayingArtworkAlt(info(title: 'Song')), 'Song のアルバムアートワーク');
      expect(
        nowPlayingArtworkAlt(info(artist: ' Artist ')),
        'Artist のアルバムアートワーク',
      );
    });

    test('⚠ どちらも無くても空にしない（読み上げに何も出ない添付にしない）', () {
      expect(nowPlayingArtworkAlt(info()), 'アルバムアートワーク');
      expect(nowPlayingArtworkAlt(info(title: '  ')), 'アルバムアートワーク');
    });
  });
}

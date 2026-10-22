import 'dart:io';

import 'package:capsicum/src/platform/now_playing/smtc_now_playing_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// #484 SMTC メソッドチャンネルの戻り値 → NowPlayingInfo 変換。ネイティブ
/// （C++/WinRT）I/O から切り出した純関数を検証する（実バスでの動作確認は
/// Windows 実機で行う）。

void main() {
  group('nowPlayingFromSmtcMetadata', () {
    test('title / artist / albumTitle を組む。SMTC は URL を持たない', () {
      final info = nowPlayingFromSmtcMetadata({
        'title': 'Song',
        'artist': 'Artist',
        'albumTitle': 'Album',
        'sourceAppId': 'Spotify.exe',
        'status': 4, // Playing
      });
      expect(info, isNotNull);
      expect(info!.title, 'Song');
      expect(info.artist, 'Artist');
      expect(info.album, 'Album');
      expect(info.sourceAppName, 'Spotify'); // .exe を落とす
      expect(info.url, isNull);
    });

    test('artist が無く title だけでも成立する', () {
      final info = nowPlayingFromSmtcMetadata({
        'title': 'Song',
        'artist': '',
        'sourceAppId': 'vlc.exe',
      });
      expect(info, isNotNull);
      expect(info!.artist, isNull);
      expect(info.title, 'Song');
    });

    test('title も artist も無ければ null', () {
      final info = nowPlayingFromSmtcMetadata({
        'title': '   ',
        'artist': '',
        'albumTitle': 'Album only',
      });
      expect(info, isNull);
    });

    test('前後の空白はトリムする', () {
      final info = nowPlayingFromSmtcMetadata({
        'title': '  Song  ',
        'artist': '  Artist  ',
      });
      expect(info!.title, 'Song');
      expect(info.artist, 'Artist');
    });

    test('sourceAppId が AUMID 等で .exe でなければそのまま使う', () {
      final info = nowPlayingFromSmtcMetadata({
        'title': 'Song',
        'sourceAppId': 'SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify',
      });
      expect(
        info!.sourceAppName,
        'SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify',
      );
    });

    test('sourceAppId 欠落時は空の sourceAppName', () {
      final info = nowPlayingFromSmtcMetadata({'title': 'Song'});
      expect(info!.sourceAppName, '');
    });

    group('ジャケット (#1274)', () {
      test('artworkPath（Windows の絶対パス）を file:// にする', () {
        const path =
            r'C:\Users\u\AppData\Local\Temp\nowplaying_native_0123456789abcdef'
            r'\nowplaying-artwork.jpg';
        final info = nowPlayingFromSmtcMetadata({
          'title': 'Song',
          'artworkPath': path,
        });
        expect(info!.artworkUrl, Uri.file(path, windows: true));
        expect(info.artworkUrl!.scheme, 'file');
        expect(info.artworkUrl!.toFilePath(windows: true), path);
        expect(info.artworkSkipReason, isNull);
      });

      test('相対パス・UNC・POSIX の形・空は捨てる', () {
        for (final path in [
          r'nowplaying-artwork.jpg',
          r'\\server\share\nowplaying-artwork.jpg',
          '/tmp/nowplaying-artwork.jpg',
          '   ',
        ]) {
          final info = nowPlayingFromSmtcMetadata({
            'title': 'Song',
            'artworkPath': path,
          });
          expect(info!.artworkUrl, isNull, reason: path);
        }
      });

      test('artworkPath が無ければ artworkUrl は null（従来どおり）', () {
        final info = nowPlayingFromSmtcMetadata({'title': 'Song'});
        expect(info!.artworkUrl, isNull);
        expect(info.artworkSkipReason, isNull);
      });

      test('書き出さなかった理由は、知っている値だけを通す', () {
        for (final reason in [
          'no_artwork',
          'read_failed',
          'unsupported_format',
          'too_large',
          'write_failed',
          'timed_out',
        ]) {
          final info = nowPlayingFromSmtcMetadata({
            'title': 'Song',
            'artworkSkipped': reason,
          });
          expect(info!.artworkSkipReason, reason);
        }
        final unknown = nowPlayingFromSmtcMetadata({
          'title': 'Song',
          'artworkSkipped': r'C:\secret\path',
        });
        expect(unknown!.artworkSkipReason, isNull);
      });
    });

    group('3 秒の打ち切り (#1324)', () {
      test('曲名まで取れていた回は曲名を出し、ジャケットだけ timed_out にする', () {
        final info = nowPlayingFromSmtcMetadata({
          'title': 'Song',
          'artist': 'Artist',
          'artworkSkipped': 'timed_out',
        });
        expect(info!.title, 'Song');
        expect(info.artworkUrl, isNull);
        expect(info.artworkSkipReason, 'timed_out');
      });

      test('曲名すら取れなかった印を見分ける', () {
        final marker = {'__nowPlayingError': 'query_timeout'};
        expect(isSmtcQueryTimeout(marker), isTrue);
        // 印だけのマップは曲として組まれない（「再生中の曲なし」と同じ）
        expect(nowPlayingFromSmtcMetadata(marker), isNull);
      });

      test('当ててはいけない形: 通常の結果・別の印', () {
        expect(isSmtcQueryTimeout({'title': 'Song'}), isFalse);
        expect(isSmtcQueryTimeout({'__nowPlayingError': 'no_track'}), isFalse);
        expect(isSmtcQueryTimeout({'__nowPlayingError': true}), isFalse);
      });

      // ⚠ ネイティブ側の形はここでしか見られない（C++ は CI で走らない）。
      // 打ち切りの経路が「曲名を捨てて null」に戻っていないことをソースで見る。
      test('⚠⚠ C++ は打ち切ったとき、取れた曲名か打ち切りの印を返す', () {
        final source = File(
          'windows/runner/smtc_now_playing.cpp',
        ).readAsStringSync();
        expect(source, contains('return TimedOutValue(*progress);'));
        expect(source, contains('ArtworkTimedOut()'));
        expect(source, contains('"query_timeout"'));
        // 曲名を置いてからジャケットへ進む順になっている
        final stash = source.indexOf('progress.text = map;');
        final artwork = source.indexOf('PutArtwork(map, ReadArtwork(props));');
        expect(stash, isNonNegative, reason: '曲名を途中経過へ置いていない');
        expect(artwork, isNonNegative, reason: 'ジャケットの読み出しが見つからない');
        expect(stash, lessThan(artwork), reason: '曲名より先にジャケットを読んでいる');
        // 以前の形（打ち切りで null を返す）が残っていない
        expect(
          RegExp(
            r'worker\.detach\(\);\s*return flutter::EncodableValue\(\);',
          ).hasMatch(source),
          isFalse,
        );
      });
    });

    test('想定外の型（数値）の title は無視', () {
      final info = nowPlayingFromSmtcMetadata({
        'title': 123,
        'artist': 'Artist',
      });
      expect(info!.title, isNull);
      expect(info.artist, 'Artist');
    });
  });
}

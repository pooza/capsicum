import 'package:capsicum/src/platform/now_playing/now_playing_provider.dart';
import 'package:capsicum/src/platform/now_playing/now_playing_resolver.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// #466 優先順位つき合成リゾルバ。優先源（Spotify）→ OS ネイティブ源の順に
/// 試し、最初に取れたものを返すこと、利用不可・null・例外の源は飛ばすことを確認。

/// テスト用の fake provider。[available] が false なら resolver はスキップする。
class _FakeProvider implements NowPlayingProvider {
  @override
  final bool isAvailable;
  final NowPlayingInfo? result;
  final bool throwOnCall;

  /// この provider の currentlyPlaying が実際に呼ばれたか。
  bool called = false;

  _FakeProvider({
    this.isAvailable = true,
    this.result,
    this.throwOnCall = false,
  });

  @override
  Future<NowPlayingInfo?> currentlyPlaying() async {
    called = true;
    if (throwOnCall) throw StateError('boom');
    return result;
  }
}

NowPlayingInfo _info(String name) => NowPlayingInfo(sourceAppName: name);

void main() {
  group('NowPlayingResolver', () {
    test('優先順位の高い源が取れたら、後続の源は呼ばない', () async {
      final high = _FakeProvider(result: _info('Spotify'));
      final low = _FakeProvider(result: _info('MPRIS'));
      final resolver = NowPlayingResolver([high, low]);

      final info = await resolver.currentlyPlaying();

      expect(info?.sourceAppName, 'Spotify');
      expect(high.called, isTrue);
      expect(low.called, isFalse);
    });

    test('優先源が null を返したら次の源にフォールバックする', () async {
      final high = _FakeProvider(result: null);
      final low = _FakeProvider(result: _info('MPRIS'));
      final resolver = NowPlayingResolver([high, low]);

      final info = await resolver.currentlyPlaying();

      expect(info?.sourceAppName, 'MPRIS');
      expect(high.called, isTrue);
      expect(low.called, isTrue);
    });

    test('利用不可（isAvailable=false）の源は呼ばずに飛ばす', () async {
      final unavailable = _FakeProvider(
        isAvailable: false,
        result: _info('Spotify'),
      );
      final available = _FakeProvider(result: _info('MPRIS'));
      final resolver = NowPlayingResolver([unavailable, available]);

      final info = await resolver.currentlyPlaying();

      expect(info?.sourceAppName, 'MPRIS');
      expect(unavailable.called, isFalse);
    });

    test('源が例外を投げても次の源にフォールバックする', () async {
      final throwing = _FakeProvider(throwOnCall: true);
      final fine = _FakeProvider(result: _info('MPRIS'));
      final resolver = NowPlayingResolver([throwing, fine]);

      final info = await resolver.currentlyPlaying();

      expect(info?.sourceAppName, 'MPRIS');
      expect(throwing.called, isTrue);
      expect(fine.called, isTrue);
    });

    test('どの源も取れなければ null', () async {
      final resolver = NowPlayingResolver([
        _FakeProvider(result: null),
        _FakeProvider(isAvailable: false, result: _info('x')),
      ]);
      expect(await resolver.currentlyPlaying(), isNull);
    });

    test('源が空なら null・hasAvailableSource は false', () async {
      const resolver = NowPlayingResolver([]);
      expect(resolver.hasAvailableSource, isFalse);
      expect(await resolver.currentlyPlaying(), isNull);
    });

    test('hasAvailableSource は利用可能な源が 1 つでもあれば true', () {
      expect(
        NowPlayingResolver([
          _FakeProvider(isAvailable: false),
          _FakeProvider(isAvailable: true),
        ]).hasAvailableSource,
        isTrue,
      );
      expect(
        NowPlayingResolver([
          _FakeProvider(isAvailable: false),
        ]).hasAvailableSource,
        isFalse,
      );
    });
  });
}

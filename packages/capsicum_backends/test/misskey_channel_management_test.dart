import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1051: Misskey のチャンネルを探す・購読する・作る。
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.response);

  final Object response;
  final List<RequestOptions> calls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    return ResponseBody.fromString(
      jsonEncode(response),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _channelJson = {
  'id': 'c1',
  'name': 'プリキュア',
  'description': '説明',
  'userId': 'u1',
  'usersCount': 12,
  'notesCount': 34,
  'isFollowing': true,
  'isFavorited': true,
  'isMuting': true,
  'isSensitive': true,
  'allowRenoteToExternal': false,
};

void main() {
  late MisskeyAdapter adapter;

  Future<_RecordingAdapter> install(Object response) async {
    adapter = await MisskeyAdapter.create('misskey.example');
    final http = _RecordingAdapter(response);
    adapter.client.dio.httpClientAdapter = http;
    return http;
  }

  test('応答の項目を読む', () async {
    await install(_channelJson);

    final channel = await adapter.getChannel('c1');

    expect(channel.description, '説明');
    expect(channel.userId, 'u1');
    expect(channel.usersCount, 12);
    expect(channel.notesCount, 34);
    expect(channel.isFollowing, isTrue);
    expect(channel.isFavorited, isTrue);
    expect(channel.isMuting, isTrue);
    expect(channel.isSensitive, isTrue);
    expect(channel.allowRenoteToExternal, isFalse);
  });

  test('項目が無いサーバーでも読める（既定に倒す）', () async {
    await install({'id': 'c1', 'name': 'n'});

    final channel = await adapter.getChannel('c1');

    expect(channel.isFollowing, isFalse);
    expect(channel.allowRenoteToExternal, isTrue);
  });

  group('一覧', () {
    test('⚠ 検索は既定の 5 件で切れないよう limit を送る', () async {
      final http = await install([_channelJson]);

      final found = await adapter.searchChannels('キュア');

      expect(found.single.id, 'c1');
      expect(http.calls.single.path, endsWith('/api/channels/search'));
      expect(http.calls.single.data, containsPair('query', 'キュア'));
      expect(http.calls.single.data, containsPair('limit', 100));
    });

    test('⚠ 自分のチャンネルも limit を送る', () async {
      final http = await install([_channelJson]);

      await adapter.getOwnedChannels();

      expect(http.calls.single.path, endsWith('/api/channels/owned'));
      expect(http.calls.single.data, containsPair('limit', 100));
    });

    test('人気・お気に入り', () async {
      final http = await install([_channelJson]);

      await adapter.getFeaturedChannels();
      await adapter.getFavoriteChannels();

      expect(http.calls.first.path, endsWith('/api/channels/featured'));
      expect(http.calls.last.path, endsWith('/api/channels/my-favorites'));
    });
  });

  group('操作は channelId を各 API へ送る', () {
    final cases = <String, Future<void> Function()>{
      'follow': () => adapter.followChannel('c1'),
      'unfollow': () => adapter.unfollowChannel('c1'),
      'favorite': () => adapter.favoriteChannel('c1'),
      'unfavorite': () => adapter.unfavoriteChannel('c1'),
      'mute/create': () => adapter.muteChannel('c1'),
      'mute/delete': () => adapter.unmuteChannel('c1'),
    };
    cases.forEach((endpoint, run) {
      test(endpoint, () async {
        final http = await install(<String, Object>{});

        await run();

        expect(http.calls.single.path, endsWith('/api/channels/$endpoint'));
        expect(http.calls.single.data, containsPair('channelId', 'c1'));
      });
    });
  });

  group('作成 / 編集', () {
    const draft = ChannelDraft(
      name: '名前',
      description: '説明',
      isSensitive: true,
      allowRenoteToExternal: false,
    );

    test('作成', () async {
      final http = await install(_channelJson);

      final created = await adapter.createChannel(draft);

      expect(created.id, 'c1');
      expect(http.calls.single.path, endsWith('/api/channels/create'));
      expect(http.calls.single.data, containsPair('name', '名前'));
      expect(http.calls.single.data, containsPair('description', '説明'));
      expect(http.calls.single.data, containsPair('isSensitive', true));
      expect(
        http.calls.single.data,
        containsPair('allowRenoteToExternal', false),
      );
    });

    test('編集は channelId を添える', () async {
      final http = await install(_channelJson);

      await adapter.updateChannel('c1', draft);

      expect(http.calls.single.path, endsWith('/api/channels/update'));
      expect(http.calls.single.data, containsPair('channelId', 'c1'));
    });

    test('⚠ 説明を空にしたら null を送って消す', () async {
      final http = await install(_channelJson);

      await adapter.updateChannel('c1', const ChannelDraft(name: '名前'));

      expect(http.calls.single.data, containsPair('description', null));
    });
  });
}

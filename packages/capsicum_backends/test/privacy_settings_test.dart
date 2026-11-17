import 'dart:convert';

import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:capsicum_core/capsicum_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// #1375: プライバシーとつながりやすさの設定を読み書きする。
///
/// ⚠ 見ているのは (1) 送るキーの名前と「null は送らない」、(2) 応答の読み方
/// （キーが無ければ出さない・値が null なら false・Misskey の
/// `requireSigninToViewContents` は無ければ false）。
class _Recorder implements HttpClientAdapter {
  _Recorder(this.response);

  final Map<String, dynamic> response;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
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

Map<String, String> _formFields(RequestOptions options) => {
  for (final field in (options.data as FormData).fields) field.key: field.value,
};

/// Mastodon 4.7 の自分の応答（必要なキーだけ）。
const _mastodonMe = <String, dynamic>{
  'id': '1',
  'locked': true,
  'discoverable': null,
  'indexable': true,
  'hide_collections': false,
  'noindex': true,
};

/// Misskey の `/api/i`（必要なキーだけ）。`requireSigninToViewContents` は
/// false のとき省かれる。
const _misskeyMe = <String, dynamic>{
  'id': 'a',
  'isLocked': false,
  'isExplorable': true,
  'autoAcceptFollowed': true,
  'publicReactions': false,
  'followingVisibility': 'followers',
  'followersVisibility': 'private',
  'hideOnlineStatus': true,
  'noCrawle': false,
  'preventAiLearning': true,
};

void main() {
  group('Mastodon', () {
    Future<(MastodonAdapter, _Recorder)> adapterWith(
      Map<String, dynamic> response,
    ) async {
      final adapter = await MastodonAdapter.create('mastodon.example');
      final http = _Recorder(response);
      adapter.client.dio.httpClientAdapter = http;
      return (adapter, http);
    }

    test('verify_credentials から読む', () async {
      final (adapter, http) = await adapterWith(_mastodonMe);
      final s = await adapter.getPrivacySettings();

      expect(http.requests.single.path, '/api/v1/accounts/verify_credentials');
      expect(s.locked, isTrue);
      expect(s.discoverable, isFalse, reason: '値が null（未設定）は false');
      expect(s.indexable, isTrue);
      expect(s.hideCollections, isFalse);
      expect(s.searchEngineHidden, isTrue);
      expect(s.searchEngineEditable, isFalse, reason: 'noindex は API で変えられない');
      expect(s.autoAcceptFollowed, isNull, reason: 'Misskey の項目は出さない');
      expect(s.followingVisibility, isNull);
    });

    test('⚠ キーが無い項目は出さない（indexable の無い古いサーバー）', () async {
      final (adapter, _) = await adapterWith({'id': '1', 'locked': false});
      final s = await adapter.getPrivacySettings();

      expect(s.locked, isFalse);
      expect(s.indexable, isNull);
      expect(s.hideCollections, isNull);
      expect(s.searchEngineHidden, isNull);
    });

    test('変えた項目だけを update_credentials で送る', () async {
      final (adapter, http) = await adapterWith(_mastodonMe);
      await adapter.updatePrivacySettings(
        const PrivacySettings(indexable: false, hideCollections: true),
      );

      final request = http.requests.single;
      expect(request.method, 'PATCH');
      expect(request.path, '/api/v1/accounts/update_credentials');
      expect(_formFields(request), {
        'indexable': 'false',
        'hide_collections': 'true',
      });
    });

    test('承認制・おすすめへの掲載も送れる（プロフィール編集から移した）', () async {
      final (adapter, http) = await adapterWith(_mastodonMe);
      await adapter.updatePrivacySettings(
        const PrivacySettings(locked: false, discoverable: true),
      );

      expect(_formFields(http.requests.single), {
        'locked': 'false',
        'discoverable': 'true',
      });
    });

    test('⚠ 検索エンジン（noindex）は渡しても送らない', () async {
      final (adapter, http) = await adapterWith(_mastodonMe);
      await adapter.updatePrivacySettings(
        const PrivacySettings(searchEngineHidden: false),
      );

      expect(_formFields(http.requests.single), isEmpty);
    });

    test('返すのは応答から読んだ値', () async {
      final (adapter, _) = await adapterWith(_mastodonMe);
      final s = await adapter.updatePrivacySettings(
        const PrivacySettings(locked: false),
      );

      expect(s.locked, isTrue, reason: '応答（サーバーの今の値）で返す');
    });
  });

  group('Misskey', () {
    Future<(MisskeyAdapter, _Recorder)> adapterWith(
      Map<String, dynamic> response,
    ) async {
      final adapter = await MisskeyAdapter.create('misskey.example');
      final http = _Recorder(response);
      adapter.client.dio.httpClientAdapter = http;
      return (adapter, http);
    }

    test('/api/i から読む', () async {
      final (adapter, http) = await adapterWith(_misskeyMe);
      final s = await adapter.getPrivacySettings();

      expect(http.requests.single.path, '/api/i');
      expect(s.locked, isFalse);
      expect(s.discoverable, isTrue);
      expect(s.autoAcceptFollowed, isTrue);
      expect(s.publicReactions, isFalse);
      expect(s.followingVisibility, FollowListVisibility.followers);
      expect(s.followersVisibility, FollowListVisibility.private);
      expect(s.hideOnlineStatus, isTrue);
      expect(s.searchEngineHidden, isFalse);
      expect(s.searchEngineEditable, isTrue);
      expect(s.preventAiLearning, isTrue);
      expect(s.indexable, isNull, reason: 'Mastodon の項目は出さない');
      expect(s.hideCollections, isNull);
    });

    test(
      '⚠ requireSigninToViewContents はキーが無ければ false（false のとき省かれる）',
      () async {
        final (adapter, _) = await adapterWith(_misskeyMe);
        expect(
          (await adapter.getPrivacySettings()).requireSigninToViewContents,
          isFalse,
        );

        final (adapter2, _) = await adapterWith({
          ..._misskeyMe,
          'requireSigninToViewContents': true,
        });
        expect(
          (await adapter2.getPrivacySettings()).requireSigninToViewContents,
          isTrue,
        );
      },
    );

    test('知らない公開範囲の値は出さない', () async {
      final (adapter, _) = await adapterWith({
        ..._misskeyMe,
        'followingVisibility': 'somebody',
      });

      expect((await adapter.getPrivacySettings()).followingVisibility, isNull);
    });

    test('変えた項目だけを i/update で送る（キーの名前）', () async {
      final (adapter, http) = await adapterWith(_misskeyMe);
      await adapter.updatePrivacySettings(
        const PrivacySettings(
          locked: true,
          discoverable: false,
          autoAcceptFollowed: false,
          publicReactions: true,
          followingVisibility: FollowListVisibility.public,
          followersVisibility: FollowListVisibility.followers,
          hideOnlineStatus: false,
          searchEngineHidden: true,
          preventAiLearning: false,
          requireSigninToViewContents: true,
        ),
      );

      final request = http.requests.single;
      expect(request.path, '/api/i/update');
      final body = Map<String, dynamic>.from(request.data as Map)..remove('i');
      expect(body, {
        'isLocked': true,
        'isExplorable': false,
        'autoAcceptFollowed': false,
        'publicReactions': true,
        'followingVisibility': 'public',
        'followersVisibility': 'followers',
        'hideOnlineStatus': false,
        'noCrawle': true,
        'preventAiLearning': false,
        'requireSigninToViewContents': true,
      });
    });

    test('⚠ null の項目は送らない', () async {
      final (adapter, http) = await adapterWith(_misskeyMe);
      await adapter.updatePrivacySettings(
        const PrivacySettings(preventAiLearning: true),
      );

      final body = Map<String, dynamic>.from(http.requests.single.data as Map)
        ..remove('i');
      expect(body, {'preventAiLearning': true});
    });
  });

  group('PrivacySettings.merge', () {
    test('非 null の項目だけ差し替え、searchEngineEditable は元のまま', () {
      const base = PrivacySettings(
        locked: false,
        indexable: true,
        searchEngineEditable: true,
      );
      final merged = base.merge(const PrivacySettings(locked: true));

      expect(merged.locked, isTrue);
      expect(merged.indexable, isTrue);
      expect(merged.searchEngineEditable, isTrue);
    });
  });
}

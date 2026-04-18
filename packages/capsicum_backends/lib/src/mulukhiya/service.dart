import 'package:dio/dio.dart';

class MulukhiyaAbout {
  final String version;
  final String controllerType;
  final String? packageUrl;

  const MulukhiyaAbout({
    required this.version,
    required this.controllerType,
    this.packageUrl,
  });
}

class AnnictWork {
  final int annictId;
  final String title;
  final int? seasonYear;
  final String? officialSiteUrl;
  final String? hashtag;
  final String? commandToot;

  const AnnictWork({
    required this.annictId,
    required this.title,
    this.seasonYear,
    this.officialSiteUrl,
    this.hashtag,
    this.commandToot,
  });
}

class AnnictEpisode {
  final int annictId;
  final String? numberText;
  final String? title;
  final String? hashtag;
  final String? url;
  final String? commandToot;

  const AnnictEpisode({
    required this.annictId,
    this.numberText,
    this.title,
    this.hashtag,
    this.url,
    this.commandToot,
  });
}

class MulukhiyaProgram {
  final String name;
  final String? series;
  final String? episode;
  final String? episodeSuffix;
  final String? subtitle;
  final bool air;
  final bool livecure;
  final int? minutes;
  final List<String> extraTags;

  const MulukhiyaProgram({
    required this.name,
    this.series,
    this.episode,
    this.episodeSuffix,
    this.subtitle,
    this.air = false,
    this.livecure = false,
    this.minutes,
    this.extraTags = const [],
  });
}

/// Extract the first default hashtag (without '#') from the about response.
String? _parseDefaultHashtag(dynamic value) {
  if (value is String && value.isNotEmpty) {
    return value.replaceFirst('#', '');
  }
  if (value is List && value.isNotEmpty) {
    return value.first.toString().replaceFirst('#', '');
  }
  return null;
}

class ServerLink {
  final String href;
  final String body;
  final String? icon;

  const ServerLink({required this.href, required this.body, this.icon});
}

class ServerLinkGroup {
  final String? title;
  final List<ServerLink> links;

  const ServerLinkGroup({this.title, required this.links});
}

class FavoriteTag {
  final String name;
  final String? url;
  final int count;

  const FavoriteTag({required this.name, this.url, required this.count});
}

class MediaCatalogItem {
  final String id;
  final String url;
  final String? thumbnailUrl;
  final String? createdAt;
  final String? fileName;
  final String? fileSizeStr;
  final String? type;
  final String? mediatype;
  final String? pixelSize;
  final double? duration;
  final String? accountUsername;
  final String? accountDisplayName;
  final String? statusBody;
  final String? statusPublicUrl;

  const MediaCatalogItem({
    required this.id,
    required this.url,
    this.thumbnailUrl,
    this.createdAt,
    this.fileName,
    this.fileSizeStr,
    this.type,
    this.mediatype,
    this.pixelSize,
    this.duration,
    this.accountUsername,
    this.accountDisplayName,
    this.statusBody,
    this.statusPublicUrl,
  });
}

class MediaCatalogResult {
  final List<MediaCatalogItem> items;
  final bool hasNext;

  const MediaCatalogResult({required this.items, required this.hasNext});
}

class EmojiPaletteEntry {
  final String id;
  final String name;
  final List<String> emojis;

  const EmojiPaletteEntry({
    required this.id,
    required this.name,
    required this.emojis,
  });
}

class EmojiPalettesResult {
  final List<EmojiPaletteEntry> palettes;
  final String? paletteForReaction;
  final String? paletteForMain;

  const EmojiPalettesResult({
    required this.palettes,
    this.paletteForReaction,
    this.paletteForMain,
  });

  /// Get emojis for the reaction palette (falls back to first palette).
  List<String> get reactionEmojis {
    if (paletteForReaction != null) {
      final palette = palettes
          .where((p) => p.id == paletteForReaction)
          .firstOrNull;
      if (palette != null) return palette.emojis;
    }
    return palettes.isNotEmpty ? palettes.first.emojis : const [];
  }

  /// Get emojis for the main palette (falls back to first palette).
  List<String> get mainEmojis {
    if (paletteForMain != null) {
      final palette = palettes.where((p) => p.id == paletteForMain).firstOrNull;
      if (palette != null) return palette.emojis;
    }
    return palettes.isNotEmpty ? palettes.first.emojis : const [];
  }
}

class MulukhiyaService {
  final Dio _dio;
  final String baseUrl;
  final String controllerType;
  final String version;
  final int? maxPostLength;
  final String? postLabel;
  final String? themeColorHex;
  final String? defaultHashtag;
  final String? reblogLabel;
  final bool annictEnabled;
  final List<String> adminRoleIds;
  final String? infoBotAcct;

  MulukhiyaService._({
    required Dio dio,
    required this.baseUrl,
    required this.controllerType,
    required this.version,
    this.maxPostLength,
    this.postLabel,
    this.themeColorHex,
    this.defaultHashtag,
    this.reblogLabel,
    this.annictEnabled = false,
    this.adminRoleIds = const [],
    this.infoBotAcct,
  }) : _dio = dio;

  Options _bearerOptions(String token) =>
      Options(headers: {'Authorization': 'Bearer $token'});

  /// Detect mulukhiya by requesting GET /mulukhiya/api/about.
  /// Returns [MulukhiyaService] if present, null otherwise.
  static Future<MulukhiyaService?> detect(Dio dio, String domain) async {
    try {
      final response = await dio.get(
        'https://$domain/mulukhiya/api/about',
        options: Options(
          responseType: ResponseType.json,
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
        ),
      );
      if (response.statusCode != 200) return null;
      final data = response.data is Map<String, dynamic>
          ? response.data as Map<String, dynamic>
          : null;
      if (data == null) return null;

      final package = data['package'] as Map<String, dynamic>?;
      final config = data['config'] as Map<String, dynamic>?;
      if (package == null || config == null) return null;

      final status = config['status'] as Map<String, dynamic>?;
      final theme = config['theme'] as Map<String, dynamic>?;
      final features = config['features'] as Map<String, dynamic>?;

      final adminRoleIds =
          (config['admin_role_ids'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [];

      final infoBot = config['info_bot'] as Map<String, dynamic>?;

      return MulukhiyaService._(
        dio: dio,
        baseUrl: 'https://$domain/mulukhiya/api',
        controllerType: config['controller'] as String? ?? 'mastodon',
        version: package['version'] as String? ?? '0.0.0',
        maxPostLength: status?['max_length'] as int?,
        postLabel: status?['label'] as String?,
        themeColorHex: theme?['color'] as String?,
        defaultHashtag: _parseDefaultHashtag(status?['default_hashtag']),
        reblogLabel: status?['reblog_label'] as String?,
        annictEnabled: features?['annict'] == true,
        adminRoleIds: adminRoleIds,
        infoBotAcct: infoBot?['acct'] as String?,
      );
    } catch (_) {
      // Not found or connection error — mulukhiya not present
    }
    return null;
  }

  /// GET /mulukhiya/api/health
  Future<Map<String, dynamic>> checkHealth() async {
    final response = await _dio.get('$baseUrl/health');
    return response.data as Map<String, dynamic>;
  }

  Future<MulukhiyaAbout> getAbout() async {
    final response = await _dio.get('$baseUrl/about');
    final data = response.data as Map<String, dynamic>;
    final package = data['package'] as Map<String, dynamic>;
    return MulukhiyaAbout(
      version: package['version'] as String,
      controllerType:
          (data['config'] as Map<String, dynamic>)['controller'] as String,
      packageUrl: package['url'] as String?,
    );
  }

  /// Fetch the program list for tagset selection.
  Future<Map<String, MulukhiyaProgram>> getProgram() async {
    final response = await _dio.get('$baseUrl/program');
    final data = response.data as Map<String, dynamic>;
    final programs = <String, MulukhiyaProgram>{};
    for (final entry in data.entries) {
      final v = entry.value;
      if (v is! Map<String, dynamic>) continue;
      if (v['enable'] != true && v['enable'] != 1) continue;
      programs[entry.key] = MulukhiyaProgram(
        name: entry.key,
        series: v['series'] as String?,
        episode: v['episode']?.toString(),
        episodeSuffix: v['episode_suffix'] as String? ?? '話',
        subtitle: v['subtitle'] as String?,
        air: v['air'] == true || v['air'] == 1,
        livecure: v['livecure'] == true || v['livecure'] == 1,
        minutes: v['minutes'] as int?,
        extraTags:
            (v['extra_tags'] as List?)?.map((e) => e.toString()).toList() ?? [],
      );
    }
    return programs;
  }

  /// Trigger program data update on the server.
  Future<void> updateProgram() async {
    await _dio.post('$baseUrl/program/update');
  }

  /// Get the Annict OAuth authorization URL from the server.
  /// The client_id is server-side config, so capsicum cannot build this URL.
  Future<String> getAnnictOAuthUri() async {
    final response = await _dio.get('$baseUrl/annict/oauth_uri');
    final data = response.data as Map<String, dynamic>;
    return data['oauth_uri'] as String;
  }

  /// Exchange an Annict OAuth authorization code for an access token.
  /// The token is stored server-side in the user's mulukhiya config.
  /// [snsToken] is the SNS account token for authentication.
  /// [annictCode] is the authorization code from Annict OAuth.
  Future<void> authenticateAnnict({
    required String snsToken,
    required String annictCode,
  }) async {
    await _dio.post(
      '$baseUrl/annict/auth',
      data: {'token': snsToken, 'code': annictCode},
      options: _bearerOptions(snsToken),
    );
  }

  /// Search Annict works by keyword.
  /// Returns an empty list if Annict is not enabled or the user is not
  /// authenticated with Annict.
  Future<List<AnnictWork>> searchWorks({String? keyword}) async {
    final response = await _dio.get(
      '$baseUrl/program/works',
      queryParameters: {'q': ?keyword},
    );
    final data = response.data;
    if (data is! List) return [];
    return data
        .whereType<Map<String, dynamic>>()
        .where((m) {
          return m['annictId'] is int && m['title'] is String;
        })
        .map((m) {
          return AnnictWork(
            annictId: m['annictId'] as int,
            title: m['title'] as String,
            seasonYear: m['seasonYear'] as int?,
            officialSiteUrl: m['officialSiteUrl'] as String?,
            hashtag: m['hashtag'] as String?,
            commandToot: m['command_toot'] as String?,
          );
        })
        .toList();
  }

  /// Fetch episodes for a given Annict work ID.
  Future<List<AnnictEpisode>> getEpisodes(int workId) async {
    final response = await _dio.get('$baseUrl/program/works/$workId/episodes');
    final data = response.data;
    if (data is! List) return [];
    return data
        .whereType<Map<String, dynamic>>()
        .where((m) {
          return m['annictId'] is int;
        })
        .map((m) {
          return AnnictEpisode(
            annictId: m['annictId'] as int,
            numberText: m['numberText'] as String?,
            title: m['title'] as String?,
            hashtag: m['hashtag'] as String?,
            url: m['url'] as String?,
            commandToot: m['command_toot'] as String?,
          );
        })
        .toList();
  }

  /// Fetch server custom links from /links.json.
  /// Supports both grouped (Mastodon) and flat (Misskey) formats.
  Future<List<ServerLinkGroup>> getLinks(String host) async {
    try {
      final response = await _dio.get('https://$host/links.json');
      final data = response.data;
      if (data is! List) return [];

      final groups = <ServerLinkGroup>[];
      for (final item in data) {
        if (item is! Map<String, dynamic>) continue;
        if (item.containsKey('links')) {
          // Grouped format (Mastodon)
          final rawLinks = item['links'] as List?;
          if (rawLinks == null) continue;
          final links = _parseLinks(rawLinks);
          if (links.isNotEmpty) {
            groups.add(
              ServerLinkGroup(title: item['body'] as String?, links: links),
            );
          }
        } else {
          // Flat format (Misskey) — collect into a single group
          final link = _parseLink(item);
          if (link != null) {
            groups.add(ServerLinkGroup(links: [link]));
          }
        }
      }
      return groups;
    } catch (_) {
      return [];
    }
  }

  List<ServerLink> _parseLinks(List items) {
    return items
        .whereType<Map<String, dynamic>>()
        .map(_parseLink)
        .whereType<ServerLink>()
        .toList();
  }

  ServerLink? _parseLink(Map<String, dynamic> m) {
    final href = m['href'] as String?;
    if (href == null) return null;
    return ServerLink(
      href: href,
      body: m['body'] as String? ?? href,
      icon: m['icon'] as String?,
    );
  }

  /// Restore avatar decoration to the saved state before tagset was applied.
  /// Requires the user's SNS access token for authentication.
  /// Returns true if restoration succeeded, false if not applicable (e.g. no
  /// saved state or decoration feature not available).
  Future<bool> restoreDecoration(String accessToken) async {
    try {
      await _dio.post(
        '$baseUrl/decoration/restore',
        data: {'token': accessToken},
        options: _bearerOptions(accessToken),
      );
      return true;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404 || e.response?.statusCode == 401) {
        return false;
      }
      rethrow;
    }
  }

  /// Fetch favorite tags (tags found in user profiles) with user counts.
  /// Requires `/{controller}/data/favorite_tags` to be enabled.
  /// Returns empty list if the feature is disabled (404).
  Future<List<FavoriteTag>> getFavoriteTags() async {
    try {
      final response = await _dio.get('$baseUrl/tagging/favorites');
      final data = response.data;
      if (data is Map<String, dynamic>) {
        return data.entries.map((e) {
          final value = e.value as Map<String, dynamic>;
          return FavoriteTag(
            name: e.key,
            url: value['url'] as String?,
            count: value['count'] as int? ?? 0,
          );
        }).toList();
      }
      return [];
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return [];
      rethrow;
    }
  }

  /// Update tags on a scheduled status (Mastodon only).
  /// PUT /mulukhiya/api/scheduled_status/:id/tags
  /// Returns the new scheduled status ID (the server recreates the post).
  Future<String> updateScheduledStatusTags({
    required String accessToken,
    required String id,
    required List<String> tags,
  }) async {
    final response = await _dio.put(
      '$baseUrl/scheduled_status/$id/tags',
      data: {'token': accessToken, 'tags': tags},
      options: _bearerOptions(accessToken),
    );
    final data = response.data as Map<String, dynamic>;
    return data['id'] as String;
  }

  /// DELETE /mulukhiya/api/status/nowplaying
  /// Removes NowPlaying information from a post and reposts it.
  Future<void> deleteNowPlaying({
    required String accessToken,
    required String id,
  }) async {
    await _dio.delete(
      '$baseUrl/status/nowplaying',
      data: {'token': accessToken, 'id': id},
      options: _bearerOptions(accessToken),
    );
  }

  /// POST /mulukhiya/api/status/tags
  /// Deletes the post and reposts it with the given tags.
  Future<void> updateStatusTags({
    required String accessToken,
    required String id,
    required List<String> tags,
  }) async {
    await _dio.post(
      '$baseUrl/status/tags',
      data: {'token': accessToken, 'id': id, 'tags': tags},
      options: _bearerOptions(accessToken),
    );
  }

  /// Fetch emoji palettes from the server (Misskey only).
  /// Requires the user's SNS access token for authentication.
  /// Returns structured palette data with main/reaction assignments.
  Future<EmojiPalettesResult> getEmojiPalettes({
    required String accessToken,
  }) async {
    final response = await _dio.get(
      '$baseUrl/emoji/palettes',
      queryParameters: {'token': accessToken},
      options: _bearerOptions(accessToken),
    );
    final data = response.data as Map<String, dynamic>;
    final palettes = data['palettes'] as List? ?? [];
    final reactionId = data['palette_for_reaction'] as String?;
    final mainId = data['palette_for_main'] as String?;

    final parsed = <EmojiPaletteEntry>[];
    for (final p in palettes) {
      final palette = p as Map<String, dynamic>;
      final emojis = (palette['emojis'] as List? ?? [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList();
      parsed.add(
        EmojiPaletteEntry(
          id: palette['id'] as String? ?? '',
          name: palette['name'] as String? ?? '',
          emojis: emojis,
        ),
      );
    }

    return EmojiPalettesResult(
      palettes: parsed,
      paletteForReaction: reactionId,
      paletteForMain: mainId,
    );
  }

  /// Fetch media catalog from /mulukhiya/api/media.
  /// Returns empty result if the feature is disabled (404).
  Future<MediaCatalogResult> getMediaCatalog({
    int page = 1,
    String? query,
    bool personOnly = false,
  }) async {
    try {
      final response = await _dio.get(
        '$baseUrl/media',
        queryParameters: {
          'page': page,
          if (query != null && query.isNotEmpty) 'q': query,
          if (personOnly) 'only_person': 1,
        },
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        return const MediaCatalogResult(items: [], hasNext: false);
      }
      final rawItems = data['items'] as List? ?? [];
      final hasNext = data['has_next'] as bool? ?? false;
      final items = rawItems.map((e) {
        final m = e as Map<String, dynamic>;
        final account = m['account'] as Map<String, dynamic>?;
        final status = m['status'] as Map<String, dynamic>?;
        return MediaCatalogItem(
          id: m['id']?.toString() ?? '',
          url: m['url'] as String? ?? '',
          thumbnailUrl: m['thumbnail_url'] as String?,
          createdAt: m['created_at'] as String?,
          fileName: m['file_name'] as String?,
          fileSizeStr: m['file_size_str'] as String?,
          type: m['type'] as String?,
          mediatype: m['mediatype'] as String?,
          pixelSize: m['pixel_size'] as String?,
          duration: (m['duration'] as num?)?.toDouble(),
          accountUsername: account?['username'] as String?,
          accountDisplayName: account?['display_name'] as String?,
          statusBody: status?['body'] as String?,
          statusPublicUrl: status?['public_url'] as String?,
        );
      }).toList();
      return MediaCatalogResult(items: items, hasNext: hasNext);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return const MediaCatalogResult(items: [], hasNext: false);
      }
      rethrow;
    }
  }

  /// Fetch default hashtags from /mulukhiya/api/about.
  /// The about endpoint is public (no auth required).
  Future<List<String>> getDefaultHashtags() async {
    try {
      final response = await _dio.get('$baseUrl/about');
      final data = response.data as Map<String, dynamic>?;
      if (data == null) return [];
      final config = data['config'] as Map<String, dynamic>?;
      if (config == null) return [];
      final status = config['status'] as Map<String, dynamic>?;
      if (status == null) return [];
      final defaultHashtag = status['default_hashtag'];
      if (defaultHashtag is String) {
        return [defaultHashtag.replaceFirst('#', '')];
      }
      if (defaultHashtag is List) {
        return defaultHashtag
            .map((e) => e.toString().replaceFirst('#', ''))
            .toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// 複数 acct の isCat フラグを一括取得する。
  /// モロヘイヤの `POST /account/is_cat` を呼び出し、ActivityPub actor から
  /// isCat を取得する（Redis キャッシュ付き）。
  ///
  /// 戻り値は3値: `true`（猫）/ `false`（猫でない）/ `null`（取得失敗・不明）。
  /// 通信エラー時は `null` を返す（空 Map と区別するため）。
  Future<Map<String, bool?>?> fetchIsCat({
    required String accessToken,
    required List<String> accts,
  }) async {
    if (accts.isEmpty) return const {};
    try {
      final response = await _dio.post(
        '$baseUrl/account/is_cat',
        data: {'token': accessToken, 'accts': accts},
        options: _bearerOptions(accessToken),
      );
      final data = response.data as Map<String, dynamic>? ?? {};
      return {
        for (final entry in data.entries)
          entry.key: entry.value == null ? null : entry.value == true,
      };
    } catch (_) {
      return null;
    }
  }
}

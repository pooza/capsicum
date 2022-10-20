import 'dart:convert';
import 'package:http/http.dart' as http;

class Nodeinfo {
  String _domain = '';
  Map<dynamic, dynamic> _coreData = {};
  Map<dynamic, dynamic> _mastodonInstanceData = {};
  Map<dynamic, dynamic> _mulukhiyaAboutData = {};

  Nodeinfo(String domain) {
    _domain = domain;
  }

  Future load() async {
    await loadCoreData();
    await loadMastodonInstanceData();
    await loadMulukhiyaAboutData();
  }

  Future loadCoreData() async {
    try {
      var response = await http.get(Uri.https(domain, '/nodeinfo/2.0'));
      _coreData = await jsonDecode(response.body);
    } catch (e) {
      print(e);
    }
  }

  Future loadMastodonInstanceData() async {
    try {
      var response = await http.get(Uri.https(domain, '/api/v1/instance'));
      _mastodonInstanceData = await jsonDecode(response.body);
    } catch (e) {
      print(e);
    }
  }

  Future loadMulukhiyaAboutData() async {
    try {
      var response = await http.get(Uri.https(domain, '/mulukhiya/api/about'));
      _mulukhiyaAboutData = await jsonDecode(response.body);
    } catch (e) {
      print(e);
    }
  }

  String get domain => _domain;

  String? get title => _mastodonInstanceData['title'];

  String? get version => _mastodonInstanceData['version'];

  Uri? get uri {
    if (_mastodonInstanceData['uri'] != null) {
      try {
        return Uri.https(_mastodonInstanceData['uri']);
      } catch (e) {
        return Uri.parse(_mastodonInstanceData['uri']);
      }
    }
  }

  Uri? get thumbnailUri {
    if (_mastodonInstanceData['thumbnail'] != null) {
      return Uri.parse(_mastodonInstanceData['thumbnail']);
    }
  }

  String? get description => _mastodonInstanceData['description'];

  String? get shortDescription => _mastodonInstanceData['short_description'] ?? _mastodonInstanceData['description'];

  bool get registerable => _mastodonInstanceData['registrations'] ?? true;

  bool get mulukhiya => (_mulukhiyaAboutData['config'] != null);

  int? get statusesMaxCharacters {
    try {
      return _mastodonInstanceData['configuration']['statuses']['max_characters'];
    } catch (e) {
      return null;
    }
  }

  String? get spoilerText {
    if (mulukhiya) {
      return _mulukhiyaAboutData['config']['status']['spoiler']['text'];
    }
  }

  String? get spoilerEmoji {
    if (mulukhiya) {
      return _mulukhiyaAboutData['config']['status']['spoiler']['shortcode'];
    }
  }

  String? get defaultHashtag {
    if (mulukhiya) {
      return _mulukhiyaAboutData['config']['status']['default_hashtag'];
    }
  }
}

import 'dart:convert';
import 'package:http/http.dart' as http;

class Nodeinfo {
  String _domain = '';
  Map<dynamic, dynamic> _coreData = {};
  Map<dynamic, dynamic> _mulukhiyaData = {};

  Nodeinfo(String domain) {
    _domain = domain;
  }

  Future load() async {
    await loadCoreData();
    await loadMulukhiyaData();
  }

  Future loadCoreData() async {
    try {
      var response = await http.get(Uri.https(domain, '/api/v1/instance'));
      _coreData = await jsonDecode(response.body);
    } catch (e) {
      print(e);
    }
  }

  Future loadMulukhiyaData() async {
    try {
      var response = await http.get(Uri.https(domain, '/mulukhiya/api/about'));
      _mulukhiyaData = await jsonDecode(response.body);
    } catch (e) {
      print(e);
    }
  }

  String get domain => _domain;

  String? get title => _coreData['title'];

  String? get version => _coreData['version'];

  Uri? get uri {
    if (_coreData['uri'] != null) {
      try {
        return Uri.https(_coreData['uri']);
      } catch (e) {
        return Uri.parse(_coreData['uri']);
      }
    }
  }

  Uri? get thumbnailUri {
    if (_coreData['thumbnail'] != null) {
      return Uri.parse(_coreData['thumbnail']);
    }
  }

  String? get description => _coreData['description'];

  String? get shortDescription => _coreData['short_description'] ?? _coreData['description'];

  bool get registerable => _coreData['registrations'] ?? true;

  bool get mulukhiya => (_mulukhiyaData['config'] != null);

  int? get statusesMaxCharacters {
    try {
      return _coreData['configuration']['statuses']['max_characters'];
    } catch (e) {
      return null;
    }
  }

  String? get spoilerText {
    if (mulukhiya) {
      return _mulukhiyaData['config']['status']['spoiler']['text'];
    }
  }

  String? get spoilerEmoji {
    if (mulukhiya) {
      return _mulukhiyaData['config']['status']['spoiler']['shortcode'];
    }
  }

  String? get defaultHashtag {
    if (mulukhiya) {
      return _mulukhiyaData['config']['status']['default_hashtag'];
    }
  }
}

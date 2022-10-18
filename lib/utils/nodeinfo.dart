import 'dart:convert';

class Nodeinfo {
  String _json = '';
  Map<dynamic, dynamic> _data = {};

  Future load(String json) async {
    _json = json;
    _data = await jsonDecode(_json);
    return _data;
  }

  String get json => _json;

  Map<dynamic, dynamic> get data => _data;

  String get title => _data['title'];

  String get version => _data['version'];

  Uri get uri {
    try {
      return Uri.https(_data['uri']);
    } catch (e) {
      return Uri.parse(_data['uri']);
    }
  }

  Uri? get thumbnailUri => Uri.parse(_data['thumbnail']);

  String? get description => _data['description'];

  String? get shortDescription => _data['short_description'] ?? _data['description'];

  bool get registerable => _data['registrations'] ?? true;
}

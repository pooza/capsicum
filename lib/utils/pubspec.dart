import 'package:flutter/services.dart' show rootBundle;
import 'package:yaml/yaml.dart';

class Pubspec {
  String _yaml = '';
  Map<dynamic, dynamic> _data = {};

  Future load() async {
    _yaml = await rootBundle.loadString('config/pubspec.yaml');
    _data = await loadYaml(_yaml);
    return _data;
  }

  String get yaml => _yaml;

  String get title => _data['name'];

  Map<dynamic, dynamic> get data => _data;
}

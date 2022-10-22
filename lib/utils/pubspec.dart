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

  Map<dynamic, dynamic> get data => _data;

  String get title => _data['name'];

  String get version => _data['version'];

  String get description => _data['description'];

  List<dynamic> get instances {
    return _data['capsicum']['instances'];
  }
}

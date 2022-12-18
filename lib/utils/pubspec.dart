import 'package:flutter/services.dart' show rootBundle;
import 'package:yaml/yaml.dart';

class Pubspec {
  String yaml = '';
  Map<dynamic, dynamic> data = {};

  Future load() async {
    yaml = await rootBundle.loadString('config/pubspec.yaml');
    data = await loadYaml(yaml);
    return data;
  }

  String get title => data['name'];

  String get version => data['version'];

  List<dynamic> get instances {
    return data['capsicum']['instances'];
  }
}

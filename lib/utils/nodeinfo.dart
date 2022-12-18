import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

class Nodeinfo {
  final Logger logger = Logger(printer: PrettyPrinter(colors: false));
  final String domain;
  Map<dynamic, dynamic> _coreData = {};
  Map<dynamic, dynamic> _mastodonInstanceData = {};

  Nodeinfo({
    required this.domain,
  });

  Future load() async {
    await loadCoreData();
    await loadMastodonInstanceData();
  }

  Future loadCoreData() async {
    try {
      var response = await http.get(Uri.https(domain, '/nodeinfo/2.0.json'));
      _coreData = await jsonDecode(utf8.decoder.convert(response.bodyBytes));
    } catch (e) {
      logger.w(e);
    }
  }

  Future loadMastodonInstanceData() async {
    try {
      var response = await http.get(Uri.https(domain, '/api/v1/instance'));
      _mastodonInstanceData = await jsonDecode(utf8.decoder.convert(response.bodyBytes));
    } catch (e) {
      logger.w(e);
    }
  }
}

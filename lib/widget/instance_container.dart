import 'package:capsicum/utils/nodeinfo.dart';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';

class InstanceContainer extends StatelessWidget {
  final Logger _logger = Logger(printer: PrettyPrinter(colors: false));
  final String domain;

  InstanceContainer({super.key, required this.domain});

  Uri? get uri {
    if (domain != '') {
      return Uri.https(domain);
    }
    return null;
  }

  Future<Nodeinfo?> createNodeinfo() async {
    Nodeinfo? instance;
    if (domain != '') {
      instance = Nodeinfo(domain);
      await instance.load();
      return instance;
    }
    return null;
  }

  Future<Image> getThumbnail() async {
    Image? thumbnail;
    Nodeinfo? nodeinfo = await createNodeinfo();
    Uri? uri = nodeinfo?.thumbnailUri;
    if (uri != null) {
      try {
        thumbnail = Image(image: NetworkImage(uri.toString()));
      } catch (e) {
        _logger.w(e);
        thumbnail = const Image(image: AssetImage('assets/spacer.gif'));
      }
    }
    return thumbnail ?? (const Image(image: AssetImage('assets/spacer.gif')));
  }

  Future<Map<String, dynamic>> getInformations() async {
    Nodeinfo? nodeinfo = await createNodeinfo();
    Map<String, dynamic> values = <String, dynamic>{};
    if (nodeinfo != null) {
      await nodeinfo.load();
      values['title'] = (nodeinfo.title ?? '');
      values['short_description'] = (nodeinfo.shortDescription ?? '(空欄)');
      values['sns_type'] = '${nodeinfo.softwareName}: ${nodeinfo.softwareVersion}';
      values['default_hashtag'] = 'デフォルトタグ: ${nodeinfo.defaultHashtag ?? '不明'}';
      values['mulukhiya_version'] = 'モロヘイヤ: ${nodeinfo.mulukhiyaVersion ?? '無効'}';
      values['software_name'] = (nodeinfo.softwareName ?? '');
      values['software_version'] = (nodeinfo.softwareVersion ?? '');
    }
    return values;
  }

  @override
  Widget build(BuildContext context) {
    return Container();
  }
}

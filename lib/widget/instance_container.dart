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
      thumbnail = Image(image: NetworkImage(uri.toString()));
    }
    return thumbnail ?? (const Image(image: AssetImage('assets/spacer.gif')));
  }

  @override
  Widget build(BuildContext context) {
    return Container();
  }
}

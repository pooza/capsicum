import 'package:flutter/material.dart';
import 'package:logger/logger.dart';

class InstanceContainer extends StatelessWidget {
  final Logger logger = Logger(printer: PrettyPrinter(colors: false));
  final String? domain;

  InstanceContainer({
    super.key,
    this.domain,
  });

  Uri? get uri {
    if (domain != null) {
      return Uri.https(domain ?? '');
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Container();
  }
}

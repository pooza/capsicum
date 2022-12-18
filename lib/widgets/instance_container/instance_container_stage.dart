import 'package:flutter/material.dart';
import 'package:logger/logger.dart';

import 'instance_container.dart';

class InstanceContainerState extends State<InstanceContainer> {
  final Logger logger = Logger(printer: PrettyPrinter(colors: false));

  Uri get uri {
    return Uri.https(widget.domain);
  }

  @override
  Widget build(BuildContext context) {
    return Container();
  }
}

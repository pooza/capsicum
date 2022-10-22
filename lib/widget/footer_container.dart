import 'package:flutter/material.dart';

class FooterContainer extends StatelessWidget {
  late final String _title;

  FooterContainer(String title, {super.key}) {
    _title = title;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        const SizedBox(height: 12),
        Text(_title),
      ],
    );
  }
}

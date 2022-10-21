import 'package:flutter/material.dart';

class FooterContainer extends StatelessWidget {
  String _title = '';

  FooterContainer(String title) {
    _title = title;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      child: Column(
        children: <Widget>[
          const SizedBox(height: 12),
          Text(_title),
        ],
      ),
    );
  }
}

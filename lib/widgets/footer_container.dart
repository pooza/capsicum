import 'package:flutter/material.dart';

class FooterContainer extends StatelessWidget {
  final String title;

  const FooterContainer({
    super.key,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        const Divider(color: Colors.green),
        const SizedBox(height: 12),
        Text(title),
      ],
    );
  }
}

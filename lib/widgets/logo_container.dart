import 'package:flutter/material.dart';

class LogoContainer extends StatelessWidget {
  const LogoContainer({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 100,
      decoration: const BoxDecoration(
        image: DecorationImage(
          fit: BoxFit.fitWidth,
          image: AssetImage('assets/logo.png'),
        ),
      ),
    );
  }
}

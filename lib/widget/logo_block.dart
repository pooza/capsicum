import 'package:flutter/material.dart';

class LogoBlock extends StatelessWidget {
  const LogoBlock({super.key});

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

import 'package:flutter/material.dart';
import 'package:capsicum/home/home_page.dart';

void main() async {
  runApp(const Capsicum());
}

class Capsicum extends StatelessWidget {
  const Capsicum({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(primarySwatch: Colors.green),
      home: const HomePage(),
    );
  }
}

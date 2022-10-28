import 'package:flutter/material.dart';
import 'package:capsicum/app/home/home_page.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]).then((_) {
    runApp(const Capsicum());
  });
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

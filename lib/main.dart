import 'package:flutter/material.dart';
import 'package:capsicum/app/home/home_page.dart';
import 'package:capsicum/app/login/login_page.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]).then((_) {
    runApp(const CapsicumApp());
  });
}

class CapsicumApp extends StatelessWidget {
  const CapsicumApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(primarySwatch: Colors.green),
      initialRoute: '/home',
      routes: {
        '/home': (BuildContext context) => const HomePage(),
        '/login': (BuildContext context) => const LoginPage(),
      },
    );
  }
}

import 'package:flutter/material.dart';
import 'package:capsicum/app/instance/instance_page.dart';
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
      initialRoute: '/instance',
      routes: {
        '/instance': (BuildContext context) => const InstancePage(),
      },
    );
  }
}

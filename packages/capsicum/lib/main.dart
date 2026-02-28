import 'package:flutter/material.dart';

void main() {
  runApp(const CapsicumApp());
}

class CapsicumApp extends StatelessWidget {
  const CapsicumApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'capsicum',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('capsicum'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: const Center(child: Text('capsicum')),
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:yaml/yaml.dart';

void main() async {
  runApp(const Capsicum());
}

class Capsicum extends StatelessWidget {
  const Capsicum({super.key});


  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'capsicum',
      theme: ThemeData(primarySwatch: Colors.green),
      home: const MyHomePage(title: 'Capsicum'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});
  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  String _yaml = 'Load YAML Data';

  void _updateYAML() {
    setState(() {
      loadYAML();
    });
  }

  Future<void> loadYAML() async {
    _yaml = await rootBundle.loadString('config/pubspec.yaml');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('You have pushed the button this many times:'),
            Text(_yaml),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _updateYAML,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}

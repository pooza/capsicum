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
      //title: 'capsicum',
      theme: ThemeData(primarySwatch: Colors.green),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  String _title = 'untitled';
  String _yaml = 'Load YAML Data';
  var _pubspec = {};

  void _loadPubspec() {
    setState(() {
      _updateTitle();
    });
  }

  Future<void> _updateTitle() async {
    _yaml = await rootBundle.loadString('config/pubspec.yaml');
    _pubspec = loadYaml(_yaml);
    _title = _pubspec['name'];
  }

  @override
  Widget build(BuildContext context) {
    Widget root = Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('You have pushed the button this many times:'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _loadPubspec,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
    return root;
  }
}

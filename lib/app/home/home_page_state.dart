import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:yaml/yaml.dart';
import 'package:capsicum/app/home/home_page.dart';

class HomePageState extends State<HomePage> {
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
      appBar: AppBar(title: Text('capsicum')),
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

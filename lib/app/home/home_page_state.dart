import 'package:flutter/material.dart';
import 'package:capsicum/app/home/home_page.dart';
import 'package:capsicum/utils/pubspec.dart';

class HomePageState extends State<HomePage> {
  Pubspec _pubspec = Pubspec();
  String _title = 'untitled';

  void loadPubspec() async {
    await _pubspec.load();
    setState(() {
      _title = _pubspec.title;
    });
  }

  @override
  Widget build(BuildContext context) {
    loadPubspec();
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('instance domain'),
          ],
        ),
      ),
    );
  }
}

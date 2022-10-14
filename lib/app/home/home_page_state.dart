import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:capsicum/app/home/home_page.dart';
import 'package:capsicum/utils/pubspec.dart';

class HomePageState extends State<HomePage> {
  final Pubspec _pubspec = Pubspec();
  String _title = 'untitled';
  String _version = '';
  List<dynamic> _accounts = [];

  void loadPubspec() async {
    await _pubspec.load();
    setState(() {
      _title = _pubspec.title;
      _version = _pubspec.version;
    });
  }

  void loadAccounts() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (prefs.getString('accounts') == null) {
      prefs.setString('accounts', '[]');
    }
    _accounts = await jsonDecode(prefs.getString('accounts') ?? '[]');
  }

  @override
  void initState() {
    loadPubspec();
    loadAccounts();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('instance domain'),
            Text(_version),
          ],
        ),
      ),
    );
  }
}

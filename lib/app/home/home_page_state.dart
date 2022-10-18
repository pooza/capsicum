import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:capsicum/app/home/home_page.dart';
import 'package:capsicum/widget/footer_container.dart';
import 'package:capsicum/utils/pubspec.dart';
import 'package:capsicum/utils/nodeinfo.dart';
import 'package:capsicum/model/account.dart';
import 'package:http/http.dart' as http;

class HomePageState extends State<HomePage> {
  final Pubspec _pubspec = Pubspec();
  String _title = 'untitled';
  String _version = '';
  String _instanceDomain = '';
  List<dynamic> _accounts = <Account>[];

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
    _accounts = await jsonDecode(prefs.getString('accounts') ?? '[]')
      .map((v) => Account(v))
      .toList();
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
      body: Column(
        children: <Widget>[
          createLogoContainer(),
          createInstanceSelectorForm(),
          FooterContainer("$_title Ver.$_version"),
        ],
      ),
    );
  }

  Widget createLogoContainer() {
    return Container(
      height: 200,
      decoration: BoxDecoration(
        image: DecorationImage(
          fit: BoxFit.fitWidth,
          image: AssetImage('lib/assets/logo.png'),
        ),
      ),
    );
  }

  Widget createInstanceSelectorForm() {
    return Form(
      child: Container(
        padding: EdgeInsets.all(12),
        child: Column(
          children: <Widget>[
            TextField(
              decoration: InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'インスタンスのドメイン名',
              ),
              onChanged: handleInstanceDomain,
            ),
          ],
        ),
      ),
    );
  }

  void handleInstanceDomain(String _instanceDomain) async {
    try {
      final response = await http.get(Uri.https(_instanceDomain, '/api/v1/instance'));
      Nodeinfo nodeinfo = Nodeinfo();
      await nodeinfo.load(response.body);

      print(nodeinfo.title);
      print(nodeinfo.version);
      print(nodeinfo.uri.toString());
      print(nodeinfo.thumbnailUri.toString());
      print(nodeinfo.description);
      print(nodeinfo.shortDescription);
      print(nodeinfo.registerable.toString());

    } catch (e) {
      print(e.toString());
    }
  }
}

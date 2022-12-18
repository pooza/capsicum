import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:capsicum/widgets/logo_container.dart';
import 'package:capsicum/widgets/footer_container.dart';
import 'package:capsicum/utils/pubspec.dart';
import 'package:capsicum/utils/account.dart';

import 'form/instance_form.dart';
import 'instance_page.dart';

class InstancePageState extends State<InstancePage> {
  final Logger logger = Logger(printer: PrettyPrinter(colors: false));
  final Pubspec pubspec = Pubspec();
  Widget footer = Container();
  AppBar appbar = AppBar(title: const Text(''));
  List<Account> accounts = <Account>[];

  @override
  void initState() {
    loadAccounts();
    loadPubspec();
    super.initState();
  }

  Future loadPubspec() async {
    await pubspec.load();
    setState(() {
      footer = FooterContainer(title: "${pubspec.title} Ver.${pubspec.version}");
      appbar = AppBar(title: Text(pubspec.title));
    });
  }

  Future loadAccounts() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (prefs.getString('accounts') == null) {
      prefs.setString('accounts', '[]');
    }
    String json = prefs.getString('accounts') ?? '[]';
    accounts = await jsonDecode(json).map((v) => Account(params: v)).toList();
    logger.i(accounts);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appbar,
      body: Column(
        children: <Widget>[
          const LogoContainer(),
          const SizedBox(height: 6),
          const InstanceForm(),
          const SizedBox(height: 6),
          footer,
        ],
      ),
    );
  }
}

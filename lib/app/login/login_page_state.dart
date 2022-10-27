import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:capsicum/app/login/login_page.dart';
import 'package:capsicum/widget/footer_container.dart';
import 'package:capsicum/utils/pubspec.dart';

class LoginPageState extends State<LoginPage> {
  final Logger _logger = Logger(printer: PrettyPrinter(colors: false));
  String _title = 'untitled';
  String _version = '';
  final Pubspec _pubspec = Pubspec();

  @override
  void initState() {
    loadPubspec();
    super.initState();
  }

  void loadPubspec() async {
    await _pubspec.load();
    setState(() {
      _title = _pubspec.title;
      _version = _pubspec.version;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: Column(
        children: <Widget>[
          FooterContainer("$_title Ver.$_version"),
        ],
      ),
    );
  }
}

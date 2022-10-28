import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:capsicum/app/login/login_page.dart';
import 'package:capsicum/widget/footer_container.dart';
import 'package:capsicum/utils/pubspec.dart';

class LoginPageState extends State<LoginPage> {
  final Logger _logger = Logger(printer: PrettyPrinter(colors: false));
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  String _title = 'untitled';
  String _version = '';
  final Pubspec _pubspec = Pubspec();
  bool _isObscurePassword = true;

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
      body: SizedBox(
        width: double.infinity,
        child: Column(
          children: <Widget>[
            buildForm(),
            FooterContainer("$_title Ver.$_version"),
          ],
        ),
      ),
    );
  }

  Widget buildForm() {
    return Container(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: <Widget>[
          TextField(
            controller: _usernameController,
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.all(6),
              border: OutlineInputBorder(),
              labelText: 'ユーザー名',
            ),
            onChanged: handleUsernameText,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.all(6),
              border: OutlineInputBorder(),
              labelText: 'パスワード',
            ),
            obscureText: _isObscurePassword,
            onChanged: handleUsernamePassword,
          ),
        ],
      ),
    );
  }

  void handleUsernameText(String username) async {
    _logger.i(username);
  }

  void handleUsernamePassword(String password) async {
    _logger.i(password);
  }
}

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logger/logger.dart';
import 'package:capsicum/app/home/home_page.dart';
import 'package:capsicum/app/login/login_page.dart';
import 'package:capsicum/widget/footer_container.dart';
import 'package:capsicum/utils/pubspec.dart';
import 'package:capsicum/utils/nodeinfo.dart';
import 'package:capsicum/utils/account.dart';

class HomePageState extends State<HomePage> {
  final Logger _logger = Logger(printer: PrettyPrinter(colors: false));
  final Pubspec _pubspec = Pubspec();
  final TextEditingController _instanceDomainTextController = TextEditingController();
  String _title = 'untitled';
  String _version = '';
  Function()? onPressed;
  List<dynamic> _accounts = <Account>[];
  Widget? _instanceThumbnail;
  final Map<String, dynamic> _nodeinfo = <String, dynamic>{};

  @override
  void initState() {
    loadPubspec();
    loadAccounts();
    _instanceThumbnail = buildInstanceThumbnail(null);
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: Column(
        children: <Widget>[
          buildLogoContainer(),
          const SizedBox(height: 6),
          buildForm(),
          const SizedBox(height: 6),
          buildInstanceInfo(),
          FooterContainer("$_title Ver.$_version"),
        ],
      ),
    );
  }

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
    String json = prefs.getString('accounts') ?? '[]';
    _accounts = await jsonDecode(json).map((v) => Account(v)).toList();
    _logger.i(_accounts);
  }

  Widget buildLogoContainer() {
    return Container(
      height: 200,
      decoration: const BoxDecoration(
        image: DecorationImage(
          fit: BoxFit.fitWidth,
          image: AssetImage('assets/logo.png'),
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
            controller: _instanceDomainTextController,
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.all(6),
              border: OutlineInputBorder(),
              labelText: 'インスタンスのドメイン名',
            ),
            onChanged: handleInstanceDomainText,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              DropdownButton(
                isDense: true,
                items: buildDomainItems(),
                onChanged: handleInstanceDomainMenu,
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: Colors.green,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: onPressed,
                child: const Text(
                  'ログイン',
                  style: TextStyle(fontSize: 14),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<DropdownMenuItem<dynamic>>? buildDomainItems() {
    List<DropdownMenuItem<dynamic>> items = <DropdownMenuItem>[];

    for (var instance in _pubspec.instances) {
      items.add(DropdownMenuItem(
        value: instance['domain'],
        child: Text(instance['name'] ?? ''),
      ));
    }
    return items;
  }

  Image buildInstanceThumbnail(Uri? uri) {
    if (uri == null) {
      return const Image(image: AssetImage('assets/spacer.gif'));
    } else {
      return Image(image: NetworkImage(uri.toString()));
    }
  }

  void handleInstanceDomainText(String domain) async {
    Nodeinfo nodeinfo = Nodeinfo(domain);
    await nodeinfo.load();
    setState(() {
      _instanceThumbnail = buildInstanceThumbnail(nodeinfo.thumbnailUri);
      _nodeinfo['title'] = (nodeinfo.title ?? '');
      _nodeinfo['short_description'] = (nodeinfo.shortDescription ?? '(空欄)');
      _nodeinfo['sns_type'] = '${nodeinfo.softwareName}: ${nodeinfo.softwareVersion}';
      _nodeinfo['default_hashtag'] = 'デフォルトタグ: ${nodeinfo.defaultHashtag ?? '不明'}';
      _nodeinfo['mulukhiya_version'] = 'モロヘイヤ: ${nodeinfo.mulukhiyaVersion ?? '無効'}';
      onPressed = (nodeinfo.softwareName == null) ? null : handleLoginButton;
    });
  }

  void handleLoginButton() async {
    _logger.i(_instanceDomainTextController.text);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const LoginPage()),
    );
  }

  void handleInstanceDomainMenu(dynamic domain) async {
    _instanceDomainTextController.text = domain.toString();
    handleInstanceDomainText(_instanceDomainTextController.text);
  }

  Widget buildInstanceInfo() {
    return Container(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 2,
            child: Column(
              children: <Widget>[
                SizedBox(
                  width: double.infinity,
                  child: Text(
                    _nodeinfo['title'] ?? '',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.left,
                  ),
                ),
                SizedBox(
                  width: double.infinity,
                  child: Text(_nodeinfo['sns_type'] ?? '', textAlign: TextAlign.left),
                ),
                SizedBox(
                  width: double.infinity,
                  child: Text(_nodeinfo['default_hashtag'] ?? '', textAlign: TextAlign.left),
                ),
                SizedBox(
                  width: double.infinity,
                  child: Text(_nodeinfo['mulukhiya_version'] ?? '', textAlign: TextAlign.left),
                ),
                SizedBox(
                  width: double.infinity,
                  child: Text(_nodeinfo['short_description'] ?? '', textAlign: TextAlign.left),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 1,
            child: Container(
              alignment: Alignment.topCenter,
              child: _instanceThumbnail,
            ),
          ),
        ],
      ),
    );
  }
}

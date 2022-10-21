import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:capsicum/app/home/home_page.dart';
import 'package:capsicum/widget/footer_container.dart';
import 'package:capsicum/utils/pubspec.dart';
import 'package:capsicum/utils/nodeinfo.dart';
import 'package:capsicum/model/account.dart';
import 'package:logger/logger.dart';

class HomePageState extends State<HomePage> {
  final Logger _logger = Logger(printer: PrettyPrinter(colors: false));
  final Pubspec _pubspec = Pubspec();
  String _title = 'untitled';
  String _version = '';
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
          image: AssetImage('lib/assets/logo.png'),
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
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'インスタンスのドメイン名',
            ),
            onChanged: handleInstanceDomain,
          ),
        ],
      ),
    );
  }

  Image buildInstanceThumbnail(Uri? uri) {
    if (uri == null) {
      return const Image(image: AssetImage('lib/assets/spacer.gif'));
    } else {
      return Image(image: NetworkImage(uri.toString()));
    }
  }

  void handleInstanceDomain(String domain) async {
    Nodeinfo nodeinfo = Nodeinfo(domain);
    await nodeinfo.load();
    setState(() {
      _instanceThumbnail = buildInstanceThumbnail(nodeinfo.thumbnailUri);
      _nodeinfo['title'] = (nodeinfo.title ?? '');
      _nodeinfo['short_description'] = (nodeinfo.shortDescription ?? '');
      //_nodeinfo['registerable'] = nodeinfo.registerable.toString();
      //_nodeinfo['mulukhiya'] = nodeinfo.mulukhiya.toString();
      //_nodeinfo['status_max_chars'] = nodeinfo.statusesMaxCharacters.toString();
      //_nodeinfo['spoiler_text'] = (nodeinfo.spoilerText ?? '');
      //_nodeinfo['spoiler_emoji'] = (nodeinfo.spoilerEmoji ?? '');
      //_nodeinfo['default_hashtag'] = (nodeinfo.defaultHashtag ?? '');
    });
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
                Text(_nodeinfo['title'] ?? ''),
                Text(_nodeinfo['short_description'] ?? ''),
              ],
            ),
          ),
          Expanded(
            flex: 1,
            child: Container(child: _instanceThumbnail),
          ),
        ],
      ),
    );
  }
}

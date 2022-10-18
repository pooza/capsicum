import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:capsicum/app/home/home_page.dart';
import 'package:capsicum/widget/footer_container.dart';
import 'package:capsicum/utils/pubspec.dart';
import 'package:capsicum/utils/nodeinfo.dart';
import 'package:capsicum/model/account.dart';

class HomePageState extends State<HomePage> {
  final Pubspec _pubspec = Pubspec();
  String _title = 'untitled';
  String _version = '';
  String _instanceDomain = '';
  List<dynamic> _accounts = <Account>[];
  Map<String, dynamic> _nodeinfo = <String, dynamic>{};

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
    return Container(
      padding: EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.max,
        children: <Widget>[
          TextField(
            decoration: InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'インスタンスのドメイン名',
            ),
            onChanged: handleInstanceDomain,
          ),
          SizedBox(height: 6),
          Row(
            children: <Widget>[
              Text('Title: ', style: TextStyle(fontWeight: FontWeight.bold)),
              Text(_nodeinfo['title'] ?? ''),
            ],
          ),
          SizedBox(height: 6),
          Row(
            children: <Widget>[
              Text('Short Description: ', style: TextStyle(fontWeight: FontWeight.bold)),
              Text(_nodeinfo['short_description'] ?? '', overflow: TextOverflow.ellipsis),
            ],
          ),
          SizedBox(height: 6),
          Row(
            children: <Widget>[
              Text('Mulukhiya? ', style: TextStyle(fontWeight: FontWeight.bold)),
              Text(_nodeinfo['mulukhiya'] ?? ''),
            ],
          ),
          SizedBox(height: 6),
          Row(
            children: <Widget>[
              Text('Statuses Max Characters: ', style: TextStyle(fontWeight: FontWeight.bold)),
              Text(_nodeinfo['status_max_chars'] ?? ''),
            ],
          ),
          SizedBox(height: 6),
          Row(
            children: <Widget>[
              Text('Spoiler Text: ', style: TextStyle(fontWeight: FontWeight.bold)),
              Text(_nodeinfo['spoiler_text'] ?? ''),
            ],
          ),
          SizedBox(height: 6),
          Row(
            children: <Widget>[
              Text('Spoiler Emoji: ', style: TextStyle(fontWeight: FontWeight.bold)),
              Text(_nodeinfo['spoiler_emoji'] ?? ''),
            ],
          ),
          SizedBox(height: 6),
          Row(
            children: <Widget>[
              Text('Default Hashtag: ', style: TextStyle(fontWeight: FontWeight.bold)),
              Text(_nodeinfo['default_hashtag'] ?? ''),
            ],
          ),
        ],
      ),
    );
  }

  void handleInstanceDomain(String _instanceDomain) async {
    Nodeinfo nodeinfo = Nodeinfo(_instanceDomain);
    await nodeinfo.load();
    setState(() {
      _nodeinfo['title'] = (nodeinfo.title ?? '');
      _nodeinfo['version'] = (nodeinfo.version ?? '');
      _nodeinfo['uri'] = nodeinfo.uri.toString();
      _nodeinfo['thumbnail_uri'] = nodeinfo.thumbnailUri.toString();
      _nodeinfo['short_description'] = (nodeinfo.shortDescription ?? '');
      _nodeinfo['registerable'] = nodeinfo.registerable.toString();
      _nodeinfo['mulukhiya'] = nodeinfo.mulukhiya.toString();
      _nodeinfo['status_max_chars'] = nodeinfo.statusesMaxCharacters.toString();
      _nodeinfo['spoiler_text'] = (nodeinfo.spoilerText ?? '');
      _nodeinfo['spoiler_emoji'] = (nodeinfo.spoilerEmoji ?? '');
      _nodeinfo['default_hashtag'] = (nodeinfo.defaultHashtag ?? '');
    });
  }
}

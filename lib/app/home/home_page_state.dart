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
  Nodeinfo? _nodeinfo;
  String _title = 'untitled';
  String _version = '';
  String _instanceDomain = '';
  List<dynamic> _accounts = <Account>[];
  Widget? _instanceThumbnail;
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
          SizedBox(height: 6),
          buildForm(),
          SizedBox(height: 6),
          buildInstanceInfo(),
          FooterContainer("$_title Ver.$_version"),
        ],
      ),
    );
  }

  Widget buildLogoContainer() {
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

  Widget buildForm() {
    return Container(
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
    );
  }

  Widget buildInstanceThumbnail(Uri? uri) {
    if (uri == null) {
      return Image(image: AssetImage('lib/assets/spacer.gif'));
    } else {
      return Image(image: NetworkImage(uri.toString()));
    }
  }

  void handleInstanceDomain(String _instanceDomain) async {
    Nodeinfo nodeinfo = Nodeinfo(_instanceDomain);
    setState(() {
      await nodeinfo.load();
    });
  }

  Widget buildInstanceInfo() {
    List<Widget> widgets = <Widget>[];

    _instanceThumbnail = buildInstanceThumbnail(_nodeinfo.thumbnailUri);
    widgets.push(_nodeinfo.title ?? '');
    widgets.push(_nodeinfo.shortDescription ?? '');

      //_nodeinfo['title'] = (nodeinfo.title ?? '');
      //_nodeinfo['short_description'] = (nodeinfo.shortDescription ?? '');
      //_nodeinfo['registerable'] = nodeinfo.registerable.toString();
      //_nodeinfo['mulukhiya'] = nodeinfo.mulukhiya.toString();
      //_nodeinfo['status_max_chars'] = nodeinfo.statusesMaxCharacters.toString();
      //_nodeinfo['spoiler_text'] = (nodeinfo.spoilerText ?? '');
      //_nodeinfo['spoiler_emoji'] = (nodeinfo.spoilerEmoji ?? '');
      //_nodeinfo['default_hashtag'] = (nodeinfo.defaultHashtag ?? '');


    return Container(
      padding: EdgeInsets.all(12),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 2,
            child: Container(
              child: Column(
                children: widgets,
              ),
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

import 'dart:convert';

class Account {
  String _json = '';
  Map<String, dynamic> _params = {};

  Account(Map<String, dynamic> params) {
    _params = params;
  }

  String get name => _params['name'];
}

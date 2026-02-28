import 'package:dio/dio.dart';

class MastodonClient {
  final Dio dio;
  final String host;

  MastodonClient(this.host) : dio = Dio(BaseOptions(baseUrl: 'https://$host'));

  void setAccessToken(String token) {
    dio.options.headers['Authorization'] = 'Bearer $token';
  }
}

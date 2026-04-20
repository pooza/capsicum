import 'package:dio/dio.dart';

/// capsicum-relay サーバーとの通信クライアント。
///
/// リレーサーバーにデバイストークンを登録し、Web Push の受信エンドポイントを
/// 取得する。リレーサーバーは受信した Web Push を APNs / FCM に変換して転送する。
class PushRelayClient {
  static const relayBaseUrl = 'https://relay.capsicum.shrieker.net';
  static const _secret = String.fromEnvironment('RELAY_SECRET');

  final _dio = Dio(
    BaseOptions(
      baseUrl: relayBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  /// デバイストークンをリレーサーバーに登録する。
  ///
  /// 戻り値に `id`（登録解除用）と `push_token`（Web Push エンドポイント構築用）
  /// が含まれる。同一デバイストークンでの再登録は既存レコードを更新し、
  /// `push_token` は維持される。
  Future<Map<String, dynamic>> register({
    required String token,
    required String deviceType,
    required String account,
    required String server,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/register',
      data: {
        'token': token,
        'device_type': deviceType,
        'account': account,
        'server': server,
      },
      options: Options(headers: {'X-Relay-Secret': _secret}),
    );
    return response.data!;
  }

  /// リレーサーバーからデバイストークン登録を解除する。
  Future<void> unregister(int id) async {
    await _dio.delete(
      '/register/$id',
      options: Options(headers: {'X-Relay-Secret': _secret}),
    );
  }
}

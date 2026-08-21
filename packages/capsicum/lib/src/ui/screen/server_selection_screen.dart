import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../constants.dart';
import '../../preset_servers.dart';
import '../../url_helper.dart';
import '../../util/exception_scrub.dart';

class ServerSelectionScreen extends ConsumerStatefulWidget {
  const ServerSelectionScreen({super.key, this.initialHost});

  /// 接続先を埋めた状態で開く (#967)。未接続アカウントから「接続し直す」で
  /// 来たとき、ホスト名を打ち直させないため。
  final String? initialHost;

  @override
  ConsumerState<ServerSelectionScreen> createState() =>
      _ServerSelectionScreenState();
}

class _ServerSelectionScreenState extends ConsumerState<ServerSelectionScreen> {
  late final _hostController = TextEditingController(
    text: widget.initialHost ?? '',
  );
  bool _isProbing = false;
  String? _error;

  @override
  void dispose() {
    _hostController.dispose();
    super.dispose();
  }

  Future<void> _connectTo(String host) async {
    setState(() {
      _isProbing = true;
      _error = null;
    });

    try {
      // タイムアウトを明示する。#723 で probeInstance が NodeInfo → /api/meta →
      // /api/v1/instance を直列に試すようになったため、パケットを黙って捨てる
      // blackhole ホストでは無指定だと OS 既定 × 最大3回ぶんハングし得る。
      final dio = Dio(
        BaseOptions(
          connectTimeout: kNetworkConnectTimeout,
          receiveTimeout: kNetworkReceiveTimeout,
        ),
      );
      final probe = await probeInstance(dio, host);
      // async gap 後に widget が dispose されているケース (CAPSICUM-1D / #472)。
      // 以下の各 setState 前に必ず mounted ガード。
      if (!mounted) return;
      if (probe == null) {
        setState(() {
          _error = 'サポートされていないサーバーです';
          _isProbing = false;
        });
        return;
      }

      context.push(
        '/login',
        extra: {
          'host': host,
          'backendType': probe.type,
          'softwareVersion': probe.softwareVersion,
        },
      );
    } catch (e) {
      debugLogException('Server probe error', e);
      if (!mounted) return;
      setState(() {
        _error = '接続に失敗しました';
      });
    } finally {
      if (mounted) setState(() => _isProbing = false);
    }
  }

  void _onSubmit() {
    final host = _hostController.text.trim();
    if (host.isEmpty) return;
    _connectTo(host);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: _isProbing
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const SizedBox(height: 16),
                Center(
                  child: Image.asset('assets/images/logo.png', height: 96),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Text(
                    'プリセットサーバーを選択',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: 4),
                Center(
                  child: TextButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('プリセットサーバーについて'),
                    onPressed: () => launchUrlSafely(
                      AppConstants.presetServersUrl,
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                ...visiblePresetServers().map((server) {
                  return ListTile(
                    leading: const Icon(Icons.dns),
                    title: Text(server.displayName),
                    subtitle: Text(server.host),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    onTap: () => _connectTo(server.host),
                  );
                }),
                const Divider(height: 32),
                TextField(
                  controller: _hostController,
                  decoration: InputDecoration(
                    labelText: 'その他のサーバー',
                    hintText: 'example.com',
                    errorText: _error,
                    prefixIcon: const Icon(Icons.dns),
                  ),
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _onSubmit(),
                  autocorrect: false,
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _onSubmit, child: const Text('接続')),
              ],
            ),
    );
  }
}

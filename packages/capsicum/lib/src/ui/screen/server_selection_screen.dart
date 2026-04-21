import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../preset_servers.dart';

class ServerSelectionScreen extends ConsumerStatefulWidget {
  const ServerSelectionScreen({super.key});

  @override
  ConsumerState<ServerSelectionScreen> createState() =>
      _ServerSelectionScreenState();
}

class _ServerSelectionScreenState extends ConsumerState<ServerSelectionScreen> {
  final _hostController = TextEditingController();
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
      final dio = Dio();
      final probe = await probeInstance(dio, host);
      if (probe == null) {
        setState(() {
          _error = 'サポートされていないサーバーです';
          _isProbing = false;
        });
        return;
      }

      if (!mounted) return;
      context.push(
        '/login',
        extra: {
          'host': host,
          'backendType': probe.type,
          'softwareVersion': probe.softwareVersion,
        },
      );
    } catch (e) {
      setState(() {
        debugPrint('Server probe error: $e');
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
                    'サーバーを選択',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: 16),
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

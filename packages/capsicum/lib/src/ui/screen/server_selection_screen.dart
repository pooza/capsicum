import 'package:capsicum_backends/capsicum_backends.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class ServerSelectionScreen extends ConsumerStatefulWidget {
  const ServerSelectionScreen({super.key});

  @override
  ConsumerState<ServerSelectionScreen> createState() =>
      _ServerSelectionScreenState();
}

class _ServerSelectionScreenState
    extends ConsumerState<ServerSelectionScreen> {
  final _hostController = TextEditingController();
  bool _isProbing = false;
  String? _error;

  @override
  void dispose() {
    _hostController.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
    final host = _hostController.text.trim();
    if (host.isEmpty) return;

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
        extra: {'host': host, 'backendType': probe.type},
      );
    } catch (e) {
      setState(() {
        _error = '接続に失敗しました: $e';
      });
    } finally {
      if (mounted) setState(() => _isProbing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('サーバーを選択')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: _hostController,
              decoration: InputDecoration(
                labelText: 'サーバーアドレス',
                hintText: 'example.com',
                errorText: _error,
                prefixIcon: const Icon(Icons.dns),
              ),
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _onSubmit(),
              autocorrect: false,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child:
                  _isProbing
                      ? const Center(child: CircularProgressIndicator())
                      : FilledButton(
                        onPressed: _onSubmit,
                        child: const Text('接続'),
                      ),
            ),
          ],
        ),
      ),
    );
  }
}

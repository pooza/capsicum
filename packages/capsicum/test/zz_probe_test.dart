import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 破棄済み AutoDisposeAsyncNotifier の state 読み書きが実際どうなるかの実測。
class _N extends AutoDisposeAsyncNotifier<int> {
  bool disposed = false;

  @override
  Future<int> build() async {
    ref.onDispose(() => disposed = true);
    return 1;
  }

  void bump() {
    final cur = state.valueOrNull;
    if (cur == null) return;
    state = AsyncData(cur + 1);
  }

  int? peek() => state.valueOrNull;
}

final p = AsyncNotifierProvider.autoDispose<_N, int>(_N.new);

void main() {
  test('probe', () async {
    final c = ProviderContainer();
    final sub = c.listen(p, (_, _) {}, fireImmediately: true);
    await c.read(p.future);
    final n = c.read(p.notifier);

    sub.close();
    await Future<void>.delayed(Duration.zero);
    // ignore: avoid_print
    print('disposed=${n.disposed}');

    Object? readErr;
    int? peeked;
    try {
      peeked = n.peek();
    } catch (e) {
      readErr = e;
    }
    // ignore: avoid_print
    print('peek=$peeked readErr=$readErr');

    Object? writeErr;
    try {
      n.bump();
    } catch (e) {
      writeErr = e;
    }
    // ignore: avoid_print
    print('writeErr=$writeErr');

    // 破棄後に書いた値が、次に provider を読んだとき残るか（＝ゴースト）。
    final fresh = await c.read(p.future);
    // ignore: avoid_print
    print('fresh=$fresh');
    c.dispose();
  });
}

import 'package:capsicum/src/service/push_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// #948: debug ビルドの既定リレー向け先は staging。
///
/// テストは debug モードで走るため、`RELAY_BASE_URL` の上書きが無ければ staging を
/// 指すことを固定する。prod に戻ると **debug 端末のトークン（APNs サンドボックス）と
/// prod relay が食い違って 401 になる**。
///
/// ⚠ **ファイルを分けてあるのは、以前 `push_relay_announcement_unregister_test.dart`
/// に同居していて、ファイル名と中身が一致していなかったため** (#982)。向け先の
/// 既定はお知らせ購読の解除とは無関係で、探すときに見つからない。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('debug の既定リレー向け先は staging (#948)', () {
    expect(
      PushRelayClient.relayBaseUrl,
      'https://st.relay.capsicum.shrieker.net',
    );
  });
}

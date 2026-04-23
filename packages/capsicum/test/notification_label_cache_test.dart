import 'package:capsicum/src/service/notification_label_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
  });

  test('save → read で保存値が取り出せる', () async {
    await NotificationLabelCache.save(
      'alice@mstdn.b-shock.org',
      reblogLabel: 'リキュア！',
      postLabel: '投稿',
    );

    expect(
      await NotificationLabelCache.readReblog('alice@mstdn.b-shock.org'),
      'リキュア！',
    );
    expect(
      await NotificationLabelCache.readPost('alice@mstdn.b-shock.org'),
      '投稿',
    );
  });

  test('保存がないアカウントは汎用ラベル（ブースト / 投稿）に落ちる', () async {
    expect(await NotificationLabelCache.readReblog('bob@example.com'), 'ブースト');
    expect(await NotificationLabelCache.readPost('bob@example.com'), '投稿');
  });

  test('remove で該当アカウントのエントリが消える', () async {
    await NotificationLabelCache.save(
      'alice@mstdn.b-shock.org',
      reblogLabel: 'リキュア！',
      postLabel: 'トゥート',
    );
    await NotificationLabelCache.save(
      'bob@mk.example.com',
      reblogLabel: 'リノート',
      postLabel: '投稿',
    );

    await NotificationLabelCache.remove('alice@mstdn.b-shock.org');

    // alice はデフォルトに戻る、bob は残る
    expect(
      await NotificationLabelCache.readReblog('alice@mstdn.b-shock.org'),
      'ブースト',
    );
    expect(
      await NotificationLabelCache.readPost('alice@mstdn.b-shock.org'),
      '投稿',
    );
    expect(
      await NotificationLabelCache.readReblog('bob@mk.example.com'),
      'リノート',
    );
  });
}

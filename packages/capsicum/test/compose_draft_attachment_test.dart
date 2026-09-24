import 'dart:io';

import 'package:capsicum/src/model/image_overlay_layer.dart';
import 'package:capsicum/src/service/compose_draft_attachment.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #1130: 下書きが覚えたローカル添付を、実在を確かめてから戻す。
///
/// ⚠⚠ **実ファイルで見る。**「存在するか」を注入できる形にすると、検査が
/// `File.exists` を一度も通らないまま緑になる —— この機能の肝は**まさにそこ**
/// （一時領域が消える前提を壊さない）なので、本物のファイルを作って消す。
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('capsicum_draft_attachment');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  Future<String> write(String name) async {
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(const [0x89, 0x50, 0x4e, 0x47]);
    return file.path;
  }

  const layer = TextOverlayLayerSpec(
    text: 'ここにキャプション',
    color: Color(0xFFEE4455),
    nx: 0.3,
    ny: 0.8,
    sizeFrac: 0.12,
    angle: 0.1,
    opacity: 0.9,
    visible: true,
    locked: false,
  );

  group('記述の往復 (#1130)', () {
    test('レイヤ列ごと往復する', () {
      final saved = ComposeDraftAttachment(
        path: '/tmp/baked.png',
        name: 'baked.png',
        mimeType: 'image/png',
        overlaySourcePath: '/tmp/source.png',
        layers: const [layer],
        description: '実況のスクショ',
        sensitive: true,
      );

      final restored = ComposeDraftAttachment.fromJson(saved.toJson());
      expect(restored, isNotNull);
      expect(restored!.path, '/tmp/baked.png');
      expect(restored.name, 'baked.png');
      expect(restored.mimeType, 'image/png');
      expect(restored.overlaySourcePath, '/tmp/source.png');
      expect(restored.description, '実況のスクショ');
      expect(restored.sensitive, isTrue);
      expect(restored.layers, hasLength(1));
      expect(
        (restored.layers.single as TextOverlayLayerSpec).text,
        'ここにキャプション',
      );
    });

    test('⚠ 読めない記述は投げずに落とす（本文まで巻き添えにしない）', () {
      expect(ComposeDraftAttachment.fromJson(null), isNull);
      expect(ComposeDraftAttachment.fromJson(<String, Object?>{}), isNull);
      expect(
        ComposeDraftAttachment.fromJson(<String, Object?>{'path': ''}),
        isNull,
      );

      // レイヤ 1 枚が壊れていても、添付そのものは戻る。
      final restored = ComposeDraftAttachment.fromJson(<String, Object?>{
        'path': '/tmp/baked.png',
        'layers': [layer.toJson(), 'これは記述ではない'],
      });
      expect(restored, isNotNull);
      expect(restored!.layers, hasLength(1));
      // 名前が無ければパスから起こす。
      expect(restored.name, 'baked.png');
    });
  });

  group('実在の確認 (#1130)', () {
    test('実体が残っていればレイヤごと戻せる', () async {
      final baked = await write('baked.png');
      final source = await write('source.png');

      final resolved = await resolveComposeDraftAttachments([
        ComposeDraftAttachment(
          path: baked,
          name: 'baked.png',
          overlaySourcePath: source,
          layers: const [layer],
        ),
      ]);

      expect(resolved.restorable, hasLength(1));
      expect(resolved.expired, 0);
      expect(resolved.overlaysDropped, 0);
      expect(resolved.restorable.single.layers, hasLength(1));
      expect(resolved.restorable.single.overlaySourcePath, source);
    });

    test('⚠ 一時ファイルが失効していたら落として数える', () async {
      final alive = await write('alive.png');

      final resolved = await resolveComposeDraftAttachments([
        ComposeDraftAttachment(path: '${dir.path}/gone.png', name: 'gone.png'),
        ComposeDraftAttachment(path: alive, name: 'alive.png'),
      ]);

      expect(resolved.restorable, hasLength(1));
      expect(resolved.restorable.single.path, alive);
      expect(resolved.expired, 1);
    });

    test('⚠⚠ 焼き込み前の画像だけ失効したら、添付は残してレイヤを捨てる', () async {
      final baked = await write('baked.png');

      final resolved = await resolveComposeDraftAttachments([
        ComposeDraftAttachment(
          path: baked,
          name: 'baked.png',
          overlaySourcePath: '${dir.path}/source_gone.png',
          layers: const [layer],
          description: 'ALT は残す',
          sensitive: true,
        ),
      ]);

      expect(resolved.expired, 0);
      expect(resolved.overlaysDropped, 1);
      expect(resolved.restorable, hasLength(1));
      final entry = resolved.restorable.single;
      // ⚠⚠ ここが本丸。レイヤを残すと、次に編集画面を開いたときに**同じレイヤが
      // 焼き込み済みの画へもう一度乗る**。
      expect(entry.layers, isEmpty);
      expect(entry.overlaySourcePath, isNull);
      // 画と付帯情報は保つ（失うのは「もう一度編集できること」だけ）。
      expect(entry.path, baked);
      expect(entry.description, 'ALT は残す');
      expect(entry.sensitive, isTrue);
    });

    test('レイヤを持たない添付は、元画像が無くても数に入れない', () async {
      final baked = await write('plain.png');

      final resolved = await resolveComposeDraftAttachments([
        ComposeDraftAttachment(
          path: baked,
          name: 'plain.png',
          overlaySourcePath: '${dir.path}/never_existed.png',
        ),
      ]);

      expect(resolved.restorable, hasLength(1));
      expect(resolved.overlaysDropped, 0, reason: '外したレイヤが無いので伝えることもない');
    });

    test('⚠ 並びを保つ（詰め直すと「並びが変わった」に見える）', () async {
      final first = await write('1.png');
      final third = await write('3.png');

      final resolved = await resolveComposeDraftAttachments([
        ComposeDraftAttachment(path: first, name: '1.png'),
        ComposeDraftAttachment(path: '${dir.path}/2.png', name: '2.png'),
        ComposeDraftAttachment(path: third, name: '3.png'),
      ]);

      expect(resolved.restorable.map((a) => a.name).toList(), <String>[
        '1.png',
        '3.png',
      ]);
      expect(resolved.expired, 1);
    });
  });
}

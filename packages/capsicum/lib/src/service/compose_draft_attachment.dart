import 'dart:io';

import '../model/image_overlay_layer.dart';

/// 下書きが覚えておくローカル添付 1 件 (#1130)。
///
/// ## なぜ添付そのものを持つようになったか
///
/// `ComposeDraft` は長らく **件数しか持たなかった** —— ローカル添付はファイル
/// パス依存で、OS の一時領域が消えると失効するため。ところが #1129 で
/// 「焼き込み前の画像 + レイヤ列」を持つようになり、**レイヤを下書きへ残すには
/// その 2 つを指せなければならない**（レイヤだけ覚えても、重ねる相手が戻らない）。
///
/// ⚠⚠ **失効しうる前提は変えていない。**パスを覚えるだけで、ファイルの寿命は
/// OS のものから 1 ミリ秒も延びない。復元側 ([resolveComposeDraftAttachments])
/// が実在を確かめ、**消えていたら落として数を伝える**。
///
/// ## ⚠ ドライブ添付は持たない
///
/// ドライブ添付はサーバー上の実体で、戻すには id から取り直す API 呼び出しが
/// 要る（レイヤも乗らない —— 編集画面はローカル画像にしか開けない）。この枠は
/// 「レイヤを戻す」ためのもので、ドライブ添付は従来どおり**件数だけ**数える。
class ComposeDraftAttachment {
  const ComposeDraftAttachment({
    required this.path,
    required this.name,
    this.mimeType,
    this.overlaySourcePath,
    this.layers = const [],
    this.description = '',
    this.sensitive = false,
  });

  /// 投稿に使うファイル（レイヤを重ねたなら**焼き込み済み**のほう）。
  final String path;

  /// 表示名。`XFile` はパスから導けるが、一時ファイルは連番の名前になるので
  /// 保存時の名前をそのまま持つ。
  final String name;

  final String? mimeType;

  /// レイヤを焼き込む**前**の画像 (#1129)。重ねていなければ null。
  final String? overlaySourcePath;

  /// [overlaySourcePath] に重ねたレイヤ列（先頭が最背面）。
  final List<OverlayLayerSpec> layers;

  final String description;
  final bool sensitive;

  /// ⚠⚠ **[layers] を足したらここと [fromJson] の両方を直す。**
  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'name': name,
    if (mimeType != null) 'mimeType': mimeType,
    if (overlaySourcePath != null) 'overlaySourcePath': overlaySourcePath,
    if (layers.isNotEmpty)
      'layers': [for (final layer in layers) layer.toJson()],
    if (description.isNotEmpty) 'description': description,
    if (sensitive) 'sensitive': true,
  };

  /// [toJson] の逆。**読めなければ null**（投げない）。
  ///
  /// ⚠ 壊れた 1 件で復元全体を落とすと**本文まで戻らなくなる**ので、読めた
  /// ぶんだけ拾う。レイヤも同じ方針（[OverlayLayerSpec.fromJson] が null を
  /// 返したぶんは捨てる）。
  static ComposeDraftAttachment? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = raw.cast<Object?, Object?>();
    final path = json['path'];
    if (path is! String || path.isEmpty) return null;
    final name = json['name'];
    final mimeType = json['mimeType'];
    final overlaySourcePath = json['overlaySourcePath'];
    final rawLayers = json['layers'];
    final description = json['description'];
    return ComposeDraftAttachment(
      path: path,
      name: name is String && name.isNotEmpty ? name : _basename(path),
      mimeType: mimeType is String ? mimeType : null,
      overlaySourcePath: overlaySourcePath is String ? overlaySourcePath : null,
      layers: rawLayers is! List
          ? const []
          : [
              // ⚠ 読めなかったレイヤは落として先へ進む（`?` は null 要素を捨てる）。
              for (final entry in rawLayers) ?OverlayLayerSpec.fromJson(entry),
            ],
      description: description is String ? description : '',
      sensitive: json['sensitive'] == true,
    );
  }

  /// 実在を確かめたうえで、復元に使う形へ整えたもの。
  ///
  /// ⚠⚠ **焼き込み前の画像が失効していたらレイヤごと捨てる。**残すと
  /// `overlayBase` が焼き込み済みのファイルへ落ちるので、**次に編集画面を開いた
  /// ときに同じレイヤがもう一度乗る**（`_MediaEntry.replaceFile` が控えを捨てる
  /// のと同じ理由）。画は保たれ、失うのは「もう一度編集できること」だけ。
  ComposeDraftAttachment withoutOverlay() => ComposeDraftAttachment(
    path: path,
    name: name,
    mimeType: mimeType,
    description: description,
    sensitive: sensitive,
  );

  static String _basename(String path) {
    final index = path.lastIndexOf(RegExp(r'[/\\]'));
    return index < 0 ? path : path.substring(index + 1);
  }
}

/// [resolveComposeDraftAttachments] の結果 (#1130)。
class ComposeDraftAttachmentRestore {
  const ComposeDraftAttachmentRestore({
    required this.restorable,
    required this.expired,
    required this.overlaysDropped,
  });

  /// 実体が残っていて、そのまま添付に戻せるぶん。
  final List<ComposeDraftAttachment> restorable;

  /// 一時ファイルが消えていて戻せなかった件数。
  final int expired;

  /// 添付は戻せたが、**焼き込み前の画像が消えていてレイヤを捨てた**件数。
  final int overlaysDropped;
}

/// 保存してあった添付のうち、いま実在するものだけを選り分ける (#1130)。
///
/// ⚠ **順序を保つ。**添付の並びは投稿時のメディアの並びそのもので、詰め直すと
/// 「1 枚消えた」ではなく「並びが変わった」に見える。
Future<ComposeDraftAttachmentRestore> resolveComposeDraftAttachments(
  List<ComposeDraftAttachment> saved,
) async {
  final restorable = <ComposeDraftAttachment>[];
  var expired = 0;
  var overlaysDropped = 0;

  for (final attachment in saved) {
    if (!await File(attachment.path).exists()) {
      expired++;
      continue;
    }
    final source = attachment.overlaySourcePath;
    if (source == null) {
      restorable.add(attachment);
      continue;
    }
    if (await File(source).exists()) {
      restorable.add(attachment);
    } else {
      // ⚠ レイヤは捨てるが添付は残す（画は焼き込み済みで生きている）。
      if (attachment.layers.isNotEmpty) overlaysDropped++;
      restorable.add(attachment.withoutOverlay());
    }
  }

  return ComposeDraftAttachmentRestore(
    restorable: restorable,
    expired: expired,
    overlaysDropped: overlaysDropped,
  );
}

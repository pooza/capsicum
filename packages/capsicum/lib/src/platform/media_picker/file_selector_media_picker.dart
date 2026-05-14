import 'package:cross_file/cross_file.dart';
import 'package:file_selector/file_selector.dart'
    show XTypeGroup, openFile, openFiles;

import 'media_picker.dart';

/// Linux / Windows 向け実装。OS ネイティブのファイルダイアログを使う。
/// macOS でも動くが、image_picker_macos が internal で file_selector を
/// 呼ぶので冗長。macOS は [ImagePickerMediaPicker] に任せる。
class FileSelectorMediaPicker implements MediaPicker {
  static const _imageGroup = XTypeGroup(
    label: '画像',
    extensions: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp'],
    mimeTypes: ['image/*'],
  );

  static const _videoGroup = XTypeGroup(
    label: '動画',
    extensions: ['mp4', 'mov', 'webm', 'mkv', 'avi', 'm4v', '3gp'],
    mimeTypes: ['video/*'],
  );

  // file_selector は acceptedTypeGroups の 1 番目をネイティブダイアログの
  // 初期フィルタにする (Linux GTK / Windows どちらも)。投稿フォームは
  // 画像 / 動画を一つのボタンで添付する UI なので、初期フィルタを「画像のみ」
  // にすると動画ファイルが一覧から消えて「動画が消えた」誤解を招く (#490)。
  // 画像 + 動画を含む統合グループを先頭に置き、必要に応じてサブフィルタで
  // 絞り込めるようにする。
  static const _allMediaGroup = XTypeGroup(
    label: '画像 / 動画',
    extensions: [
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'heic',
      'heif',
      'bmp',
      'mp4',
      'mov',
      'webm',
      'mkv',
      'avi',
      'm4v',
      '3gp',
    ],
    mimeTypes: ['image/*', 'video/*'],
  );

  @override
  Future<XFile?> pickImage() {
    return openFile(acceptedTypeGroups: const [_imageGroup]);
  }

  @override
  Future<List<XFile>> pickMultipleMedia() {
    return openFiles(
      acceptedTypeGroups: const [_allMediaGroup, _imageGroup, _videoGroup],
    );
  }
}

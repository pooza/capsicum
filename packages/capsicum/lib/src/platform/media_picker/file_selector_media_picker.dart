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

  @override
  Future<XFile?> pickImage() {
    return openFile(acceptedTypeGroups: const [_imageGroup]);
  }

  @override
  Future<List<XFile>> pickMultipleMedia() {
    return openFiles(acceptedTypeGroups: const [_imageGroup, _videoGroup]);
  }
}

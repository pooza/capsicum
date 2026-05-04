import 'package:cross_file/cross_file.dart';
import 'package:image_picker/image_picker.dart' show ImagePicker, ImageSource;

import 'media_picker.dart';

/// iOS / Android / macOS 向け実装。OS ネイティブのギャラリー UI を出す。
class ImagePickerMediaPicker implements MediaPicker {
  final ImagePicker _picker;

  ImagePickerMediaPicker({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  @override
  Future<XFile?> pickImage() {
    return _picker.pickImage(source: ImageSource.gallery);
  }

  @override
  Future<List<XFile>> pickMultipleMedia() {
    return _picker.pickMultipleMedia();
  }
}

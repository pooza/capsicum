import 'package:cross_file/cross_file.dart';

/// プラットフォーム差を吸収するメディア選択インターフェース (#329)。
///
/// モバイル / macOS は image_picker（OS ネイティブのギャラリー UI）、
/// Linux / Windows は file_selector（OS ネイティブのファイルダイアログ）に
/// 切り替える。戻り値の [XFile] は両プラグインで共通の cross_file 型なので
/// 呼び出し側のコードは変わらない。
abstract class MediaPicker {
  /// ギャラリーから 1 枚画像を選択する。アバター / バナー / 設定画面の
  /// 背景画像など、単独の画像入力で使う。
  Future<XFile?> pickImage();

  /// 画像 / 動画を複数選択する。投稿フォームの添付メディア入力で使う。
  /// 戻り値は MIME / 拡張子で image / video のどちらかに分類される想定。
  Future<List<XFile>> pickMultipleMedia();
}

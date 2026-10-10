import '../../model/user.dart';

abstract mixin class ReportSupport {
  /// [forward] は「相手のサーバーの管理者にも知らせる」(#1203)。
  /// [reportForwardHost] が null を返す相手では無視される。
  Future<void> reportPost(
    String postId,
    String authorId, {
    String? comment,
    bool forward = false,
  });

  /// 投稿を伴わない、ユーザー単位の通報 (#998)。
  ///
  /// Mastodon の `POST /api/v1/reports` は `status_ids` が任意、Misskey の
  /// `POST /api/users/report-abuse` はもともとユーザー単位なので、どちらも
  /// 投稿を特定せずに通報できる。プロフィール画面からの導線がこれを使う。
  Future<void> reportUser(
    String userId, {
    String? comment,
    bool forward = false,
  });

  /// [user] への通報を転送できる先のサーバー (#1203)。転送できなければ null。
  ///
  /// ⚠ **null のとき、画面は「相手のサーバーにも知らせる」を出さない。**
  /// 相手が自分と同じサーバーに居る（転送する先が無い）か、バックエンドに
  /// 通報者が転送を指定する口が無い（Misskey の `report-abuse`）。
  ///
  /// ⚠ **転送しない通報は、自分のサーバーの管理者にしか届かない。**リモートの
  /// 相手を止められるのは相手のサーバーの管理者なので、出せるときは出す。
  String? reportForwardHost(User user) => null;
}

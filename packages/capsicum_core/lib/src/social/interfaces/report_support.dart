import '../../model/user.dart';

/// 通報の分類 (#1257)。Mastodon の `Report#category` と同じ 4 つ。
///
/// ⚠ **[other] がサーバーの既定**で、送らなければ [other] として受ける。
/// ⚠⚠ **[violation] は違反したルール（`rule_ids`）を 1 つ以上添えないと
/// サーバーが断る**（`Report#validate_rule_ids`）。
enum ReportCategory { other, spam, legal, violation }

/// 通報で「違反した」と選べるサーバーのルール (#1257)。
class ReportRule {
  const ReportRule({required this.id, required this.text, this.hint});

  final String id;
  final String text;

  /// ルールの補足。無ければ null。
  final String? hint;
}

abstract mixin class ReportSupport {
  /// [forward] は「相手のサーバーの管理者にも知らせる」(#1203)。
  /// [reportForwardHost] が null を返す相手では無視される。
  ///
  /// [category] と [ruleIds] は [supportsReportCategory] が false の相手では
  /// 無視される (#1257)。
  Future<void> reportPost(
    String postId,
    String authorId, {
    String? comment,
    bool forward = false,
    ReportCategory category = ReportCategory.other,
    List<String> ruleIds = const [],
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
    ReportCategory category = ReportCategory.other,
    List<String> ruleIds = const [],
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

  /// 通報に分類を添えられるか (#1257)。Mastodon だけ（Misskey の
  /// `report-abuse` には分類の口が無い）。
  bool get supportsReportCategory => false;

  /// 「サーバーのルール違反」で選べるルール (#1257)。取れなければ空。
  ///
  /// ⚠ 空のとき、画面は「サーバーのルール違反」を出さない（ルールを添えずに
  /// 送るとサーバーが断るため）。
  Future<List<ReportRule>> getReportRules() async => const [];
}

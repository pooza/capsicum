import 'attachment.dart';
import 'user.dart';

class Instance {
  final String name;
  final String? softwareName;
  final String? description;
  final String? iconUrl;
  final String? version;
  final String? themeColor;
  final int? userCount;
  final int? postCount;
  final String? contactEmail;
  final User? contactAccount;
  final String? contactUrl;
  final List<String> rules;
  final String? privacyPolicyUrl;
  final String? statusUrl;

  /// サーバーの設立日（正式オープン日）。
  ///
  /// - **モロヘイヤ導入鯖**: `/about` の `config.founded_at` を単純採用する
  ///   (#818)。運用者が `/founded_on` を手設定していればその値、未設定なら
  ///   サーバー側が下記ヒューリスティックで近似した値が入る。合流は
  ///   server_info_provider が行う。
  /// - **非モロヘイヤ鯖**: API に創立日フィールドが無いため、**最初に作られた
  ///   アカウントの作成日**で近似する。
  ///   - Mastodon: `accounts/1` の作成日。account id は 2021-03 の timestamp_id
  ///     移行より前は連番だったため、それ以前開設の鯖には id=1（最初のローカル
  ///     アカウント）が残り真の設立日を返せる（2代目管理人の鯖でも正しい）。移行後
  ///     開設の鯖は id が snowflake になり id=1 が無いため、`contact_account`
  ///     （管理者）の作成日にフォールバックする。
  ///   - Misskey: 最古ローカルユーザーの `createdAt`。
  ///
  /// 取得不能なら null（非表示）。
  final DateTime? foundedAt;

  /// サーバーのプレ公開（限定公開）開始日。モロヘイヤ導入鯖で運用者が
  /// `/preopened_on` を手設定した時のみ非 null（`/about` の `config.preopened_at`、
  /// #818）。[foundedAt] と違い最古アカウント fallback は持たず、プレ公開を経た
  /// サーバーだけが値を持つ。`preopenedAt <= foundedAt` の関係になり、サーバー
  /// 情報画面では設立日の前に別行で表示する。取得不能・未設定なら null（非表示）。
  final DateTime? preopenedAt;

  /// 添付ファイルの種別ごとの最大サイズ（bytes）。サーバーが上限を返さない
  /// 場合は null（事前チェックをスキップして従来どおりサーバーエラー経路に
  /// 任せる）。Misskey は MIME によらず単一値のため、image/video/audio に
  /// 同じ値が入る。
  final int? imageSizeLimit;
  final int? videoSizeLimit;
  final int? audioSizeLimit;

  const Instance({
    required this.name,
    this.softwareName,
    this.description,
    this.iconUrl,
    this.version,
    this.themeColor,
    this.userCount,
    this.postCount,
    this.contactEmail,
    this.contactAccount,
    this.contactUrl,
    this.rules = const [],
    this.privacyPolicyUrl,
    this.statusUrl,
    this.foundedAt,
    this.preopenedAt,
    this.imageSizeLimit,
    this.videoSizeLimit,
    this.audioSizeLimit,
  });

  /// 一部フィールドだけ差し替えた複製を返す。プロバイダ側で NodeInfo 由来の
  /// [softwareName] を後付けするといった enrich 用途に使う。手写しの再構築だと
  /// フィールド追加のたびにコピー漏れ（例: #815 の foundedAt が #816 の再構築で
  /// 欠落した）が起きるため、複製はここに集約する。
  Instance copyWith({
    String? name,
    String? softwareName,
    String? description,
    String? iconUrl,
    String? version,
    String? themeColor,
    int? userCount,
    int? postCount,
    String? contactEmail,
    User? contactAccount,
    String? contactUrl,
    List<String>? rules,
    String? privacyPolicyUrl,
    String? statusUrl,
    DateTime? foundedAt,
    DateTime? preopenedAt,
    int? imageSizeLimit,
    int? videoSizeLimit,
    int? audioSizeLimit,
  }) => Instance(
    name: name ?? this.name,
    softwareName: softwareName ?? this.softwareName,
    description: description ?? this.description,
    iconUrl: iconUrl ?? this.iconUrl,
    version: version ?? this.version,
    themeColor: themeColor ?? this.themeColor,
    userCount: userCount ?? this.userCount,
    postCount: postCount ?? this.postCount,
    contactEmail: contactEmail ?? this.contactEmail,
    contactAccount: contactAccount ?? this.contactAccount,
    contactUrl: contactUrl ?? this.contactUrl,
    rules: rules ?? this.rules,
    privacyPolicyUrl: privacyPolicyUrl ?? this.privacyPolicyUrl,
    statusUrl: statusUrl ?? this.statusUrl,
    foundedAt: foundedAt ?? this.foundedAt,
    preopenedAt: preopenedAt ?? this.preopenedAt,
    imageSizeLimit: imageSizeLimit ?? this.imageSizeLimit,
    videoSizeLimit: videoSizeLimit ?? this.videoSizeLimit,
    audioSizeLimit: audioSizeLimit ?? this.audioSizeLimit,
  );

  /// 添付ファイル種別に対応する最大サイズ（bytes）。サーバーが上限を返さない
  /// 場合や、種別が判定できない場合は null。
  int? maxAttachmentSizeBytes(AttachmentType type) {
    switch (type) {
      case AttachmentType.image:
      case AttachmentType.gifv:
        return imageSizeLimit;
      case AttachmentType.video:
        return videoSizeLimit;
      case AttachmentType.audio:
        return audioSizeLimit;
      case AttachmentType.unknown:
        return null;
    }
  }
}

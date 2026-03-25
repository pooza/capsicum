// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'status.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

MastodonStatus _$MastodonStatusFromJson(
  Map<String, dynamic> json,
) => MastodonStatus(
  id: json['id'] as String,
  createdAt: DateTime.parse(json['created_at'] as String),
  account: MastodonAccount.fromJson(json['account'] as Map<String, dynamic>),
  content: json['content'] as String,
  visibility: json['visibility'] as String,
  favouritesCount: (json['favourites_count'] as num).toInt(),
  reblogsCount: (json['reblogs_count'] as num).toInt(),
  repliesCount: (json['replies_count'] as num).toInt(),
  favourited: json['favourited'] as bool?,
  reblogged: json['reblogged'] as bool?,
  bookmarked: json['bookmarked'] as bool?,
  inReplyToId: json['in_reply_to_id'] as String?,
  reblog: json['reblog'] == null
      ? null
      : MastodonStatus.fromJson(json['reblog'] as Map<String, dynamic>),
  quote: _readQuote(json['quote']),
  mediaAttachments: (json['media_attachments'] as List<dynamic>)
      .map((e) => MastodonMediaAttachment.fromJson(e as Map<String, dynamic>))
      .toList(),
  spoilerText: json['spoiler_text'] as String?,
  emojis: (json['emojis'] as List<dynamic>?)
      ?.map((e) => e as Map<String, dynamic>)
      .toList(),
  sensitive: json['sensitive'] as bool?,
  filtered: (json['filtered'] as List<dynamic>?)
      ?.map((e) => e as Map<String, dynamic>)
      .toList(),
  card: json['card'] as Map<String, dynamic>?,
  poll: json['poll'] as Map<String, dynamic>?,
  quotesCount: (json['quotes_count'] as num?)?.toInt(),
  quoteApproval: json['quote_approval'] as Map<String, dynamic>?,
  language: json['language'] as String?,
  url: json['url'] as String?,
);

Map<String, dynamic> _$MastodonStatusToJson(MastodonStatus instance) =>
    <String, dynamic>{
      'id': instance.id,
      'created_at': instance.createdAt.toIso8601String(),
      'account': instance.account,
      'content': instance.content,
      'visibility': instance.visibility,
      'favourites_count': instance.favouritesCount,
      'reblogs_count': instance.reblogsCount,
      'replies_count': instance.repliesCount,
      'favourited': instance.favourited,
      'reblogged': instance.reblogged,
      'bookmarked': instance.bookmarked,
      'in_reply_to_id': instance.inReplyToId,
      'reblog': instance.reblog,
      'quote': instance.quote,
      'media_attachments': instance.mediaAttachments,
      'spoiler_text': instance.spoilerText,
      'emojis': instance.emojis,
      'sensitive': instance.sensitive,
      'filtered': instance.filtered,
      'card': instance.card,
      'poll': instance.poll,
      'quotes_count': instance.quotesCount,
      'quote_approval': instance.quoteApproval,
      'language': instance.language,
      'url': instance.url,
    };

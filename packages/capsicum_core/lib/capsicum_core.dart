/// Domain models and adapter interfaces for capsicum.
library;

// Models
export 'src/model/attachment.dart';
export 'src/model/instance.dart';
export 'src/model/notification.dart';
export 'src/model/post.dart';
export 'src/model/post_draft.dart';
export 'src/model/post_scope.dart';
export 'src/model/timeline_query.dart';
export 'src/model/timeline_type.dart';
export 'src/model/user.dart';

// Social / Adapter
export 'src/social/adapter.dart';
export 'src/social/capabilities.dart';

// Feature interfaces
export 'src/social/interfaces/bookmark_support.dart';
export 'src/social/interfaces/custom_emoji_support.dart';
export 'src/social/interfaces/favorite_support.dart';
export 'src/social/interfaces/follow_support.dart';
export 'src/social/interfaces/hashtag_support.dart';
export 'src/social/interfaces/list_support.dart';
export 'src/social/interfaces/login_support.dart';
export 'src/social/interfaces/notification_support.dart';
export 'src/social/interfaces/reaction_support.dart';
export 'src/social/interfaces/search_support.dart';
export 'src/social/interfaces/stream_support.dart';

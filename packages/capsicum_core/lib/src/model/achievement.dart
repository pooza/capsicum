/// A single achievement earned by a user.
class Achievement {
  final String name;
  final DateTime unlockedAt;

  const Achievement({required this.name, required this.unlockedAt});
}

/// Rarity tier for achievement display.
enum AchievementFrame { bronze, silver, gold, platinum }

/// Display metadata for a known achievement type.
class AchievementMeta {
  final String label;
  final String emoji;
  final AchievementFrame frame;

  const AchievementMeta(this.label, this.emoji, this.frame);
}

/// Registry of all known Misskey achievement types.
const achievementCatalog = <String, AchievementMeta>{
  // --- 投稿数 ---
  'notes1': AchievementMeta('初めての投稿', '\u{270d}', AchievementFrame.bronze),
  'notes10': AchievementMeta('10 投稿', '\u{270d}', AchievementFrame.bronze),
  'notes100': AchievementMeta('100 投稿', '\u{270d}', AchievementFrame.bronze),
  'notes500': AchievementMeta('500 投稿', '\u{270d}', AchievementFrame.silver),
  'notes1000': AchievementMeta('1,000 投稿', '\u{270d}', AchievementFrame.silver),
  'notes5000': AchievementMeta('5,000 投稿', '\u{270d}', AchievementFrame.silver),
  'notes10000': AchievementMeta('10,000 投稿', '\u{270d}', AchievementFrame.gold),
  'notes20000': AchievementMeta('20,000 投稿', '\u{270d}', AchievementFrame.gold),
  'notes30000': AchievementMeta('30,000 投稿', '\u{270d}', AchievementFrame.gold),
  'notes40000': AchievementMeta('40,000 投稿', '\u{270d}', AchievementFrame.gold),
  'notes50000': AchievementMeta('50,000 投稿', '\u{270d}', AchievementFrame.platinum),
  'notes60000': AchievementMeta('60,000 投稿', '\u{270d}', AchievementFrame.platinum),
  'notes70000': AchievementMeta('70,000 投稿', '\u{270d}', AchievementFrame.platinum),
  'notes80000': AchievementMeta('80,000 投稿', '\u{270d}', AchievementFrame.platinum),
  'notes90000': AchievementMeta('90,000 投稿', '\u{270d}', AchievementFrame.platinum),
  'notes100000': AchievementMeta('100,000 投稿', '\u{270d}', AchievementFrame.platinum),

  // --- ログイン ---
  'login3': AchievementMeta('3 日ログイン', '\u{1f4c5}', AchievementFrame.bronze),
  'login7': AchievementMeta('7 日ログイン', '\u{1f4c5}', AchievementFrame.bronze),
  'login15': AchievementMeta('15 日ログイン', '\u{1f4c5}', AchievementFrame.bronze),
  'login30': AchievementMeta('30 日ログイン', '\u{1f4c5}', AchievementFrame.silver),
  'login60': AchievementMeta('60 日ログイン', '\u{1f4c5}', AchievementFrame.silver),
  'login100': AchievementMeta('100 日ログイン', '\u{1f4c5}', AchievementFrame.silver),
  'login200': AchievementMeta('200 日ログイン', '\u{1f4c5}', AchievementFrame.gold),
  'login300': AchievementMeta('300 日ログイン', '\u{1f4c5}', AchievementFrame.gold),
  'login400': AchievementMeta('400 日ログイン', '\u{1f4c5}', AchievementFrame.gold),
  'login500': AchievementMeta('500 日ログイン', '\u{1f4c5}', AchievementFrame.platinum),
  'login600': AchievementMeta('600 日ログイン', '\u{1f4c5}', AchievementFrame.platinum),
  'login700': AchievementMeta('700 日ログイン', '\u{1f4c5}', AchievementFrame.platinum),
  'login800': AchievementMeta('800 日ログイン', '\u{1f4c5}', AchievementFrame.platinum),
  'login900': AchievementMeta('900 日ログイン', '\u{1f4c5}', AchievementFrame.platinum),
  'login1000': AchievementMeta('1,000 日ログイン', '\u{1f4c5}', AchievementFrame.platinum),

  // --- アカウント ---
  'passedSinceAccountCreated1': AchievementMeta('1 周年', '\u{1f382}', AchievementFrame.bronze),
  'passedSinceAccountCreated2': AchievementMeta('2 周年', '\u{1f382}', AchievementFrame.silver),
  'passedSinceAccountCreated3': AchievementMeta('3 周年', '\u{1f382}', AchievementFrame.gold),
  'loggedInOnBirthday': AchievementMeta('誕生日ログイン', '\u{1f381}', AchievementFrame.silver),
  'loggedInOnNewYearsDay': AchievementMeta('元日ログイン', '\u{1f38d}', AchievementFrame.silver),

  // --- ソーシャル: フォロー ---
  'following1': AchievementMeta('初フォロー', '\u{1f465}', AchievementFrame.bronze),
  'following10': AchievementMeta('10 フォロー', '\u{1f465}', AchievementFrame.bronze),
  'following50': AchievementMeta('50 フォロー', '\u{1f465}', AchievementFrame.silver),
  'following100': AchievementMeta('100 フォロー', '\u{1f465}', AchievementFrame.silver),
  'following300': AchievementMeta('300 フォロー', '\u{1f465}', AchievementFrame.gold),

  // --- ソーシャル: フォロワー ---
  'followers1': AchievementMeta('初フォロワー', '\u{2b50}', AchievementFrame.bronze),
  'followers10': AchievementMeta('10 フォロワー', '\u{2b50}', AchievementFrame.bronze),
  'followers50': AchievementMeta('50 フォロワー', '\u{2b50}', AchievementFrame.silver),
  'followers100': AchievementMeta('100 フォロワー', '\u{2b50}', AchievementFrame.silver),
  'followers300': AchievementMeta('300 フォロワー', '\u{2b50}', AchievementFrame.gold),
  'followers500': AchievementMeta('500 フォロワー', '\u{2b50}', AchievementFrame.gold),
  'followers1000': AchievementMeta('1,000 フォロワー', '\u{2b50}', AchievementFrame.platinum),

  // --- エンゲージメント ---
  'noteClipped1': AchievementMeta('初クリップ', '\u{1f4ce}', AchievementFrame.bronze),
  'noteFavorited1': AchievementMeta('初ブックマーク', '\u{2764}', AchievementFrame.bronze),
  'myNoteFavorited1': AchievementMeta('投稿がブックマークされた', '\u{1f49d}', AchievementFrame.bronze),
  'profileFilled': AchievementMeta('プロフィール入力', '\u{1f464}', AchievementFrame.bronze),
  'markedAsCat': AchievementMeta('猫化', '\u{1f408}', AchievementFrame.bronze),

  // --- 実績 ---
  'collectAchievements30': AchievementMeta('実績 30 個', '\u{1f3c6}', AchievementFrame.gold),
  'viewAchievements3min': AchievementMeta('実績を 3 分眺める', '\u{1f440}', AchievementFrame.bronze),

  // --- Misskey 愛 ---
  'iLoveMisskey': AchievementMeta('I Love Misskey', '\u{2764}', AchievementFrame.silver),
  'foundTreasure': AchievementMeta('宝物発見', '\u{1f48e}', AchievementFrame.gold),
  'client30min': AchievementMeta('30 分利用', '\u{23f0}', AchievementFrame.bronze),
  'client60min': AchievementMeta('60 分利用', '\u{23f0}', AchievementFrame.silver),

  // --- 投稿タイミング ---
  'noteDeletedWithin1min': AchievementMeta('1 分以内に削除', '\u{1f5d1}', AchievementFrame.bronze),
  'postedAtLateNight': AchievementMeta('深夜の投稿', '\u{1f319}', AchievementFrame.bronze),
  'postedAt0min0sec': AchievementMeta('0 分 0 秒に投稿', '\u{23f0}', AchievementFrame.silver),
  'selfQuote': AchievementMeta('セルフ引用', '\u{1f500}', AchievementFrame.bronze),
  'htl20npm': AchievementMeta('HTL 毎分 20 投稿', '\u{1f4e8}', AchievementFrame.silver),

  // --- UI 探索 ---
  'viewInstanceChart': AchievementMeta('サーバーチャート閲覧', '\u{1f4ca}', AchievementFrame.bronze),
  'outputHelloWorldOnScratchpad': AchievementMeta('Hello, world!', '\u{1f4dd}', AchievementFrame.bronze),
  'open3windows': AchievementMeta('3 ウィンドウ', '\u{1fa9f}', AchievementFrame.bronze),
  'driveFolderCircularReference': AchievementMeta('循環参照', '\u{1f300}', AchievementFrame.silver),
  'reactWithoutRead': AchievementMeta('未読リアクション', '\u{1f440}', AchievementFrame.bronze),
  'clickedClickHere': AchievementMeta('ここをクリック', '\u{1f449}', AchievementFrame.bronze),

  // --- その他 ---
  'justPlainLucky': AchievementMeta('ただの幸運', '\u{1f340}', AchievementFrame.platinum),
  'setNameToSyuilo': AchievementMeta('しゅいろ', '\u{1f338}', AchievementFrame.silver),
  'cookieClicked': AchievementMeta('クッキークリック', '\u{1f36a}', AchievementFrame.bronze),
  'brainDiver': AchievementMeta('Brain Diver', '\u{1f9e0}', AchievementFrame.silver),
  'smashTestNotificationButton': AchievementMeta('テスト通知連打', '\u{1f514}', AchievementFrame.bronze),
  'tutorialCompleted': AchievementMeta('チュートリアル完了', '\u{1f393}', AchievementFrame.bronze),
  'bubbleGameExplodingHead': AchievementMeta('バブルゲーム: 爆発', '\u{1f92f}', AchievementFrame.silver),
  'bubbleGameDoubleExplodingHead': AchievementMeta('バブルゲーム: 2 連爆発', '\u{1f92f}', AchievementFrame.gold),
};

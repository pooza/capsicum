class Poll {
  final String id;
  final List<PollOption> options;
  final int votersCount;
  final bool multiple;
  final bool expired;
  final DateTime? expiresAt;
  final bool voted;
  final List<int> ownVotes;
  final Map<String, String> emojis;

  const Poll({
    required this.id,
    required this.options,
    this.votersCount = 0,
    this.multiple = false,
    this.expired = false,
    this.expiresAt,
    this.voted = false,
    this.ownVotes = const [],
    this.emojis = const {},
  });
}

class PollOption {
  final String title;
  final int votesCount;

  const PollOption({required this.title, this.votesCount = 0});
}

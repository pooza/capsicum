abstract mixin class PollSupport {
  Future<void> votePoll(String pollId, List<int> choices);
}

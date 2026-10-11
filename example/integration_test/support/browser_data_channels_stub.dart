/// Records nothing off the web.
class BrowserDataChannels {
  /// Starts recording.
  BrowserDataChannels();

  /// The `maxRetransmits` of each browser channel labelled [label]: none
  /// off the web.
  List<int?> maxRetransmitsOf(String label) => const [];

  /// Stops recording.
  void stop() {}
}

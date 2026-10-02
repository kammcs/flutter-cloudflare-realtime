/// One of the package's hidden remote `<audio>` elements, as the page
/// sees it.
typedef WebAudioElement = ({
  bool paused,
  double currentTime,
  String sinkId,
  int liveAudioTracks,
});

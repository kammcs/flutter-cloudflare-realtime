/// SDP from a push after a pull against the real SFU (macOS, libwebrtc
/// M150; the iPhone's is the same), trimmed to the lines that matter: no
/// candidates, ICE credentials, fingerprints or SSRCs, and fewer codecs.
///
/// The session pushed a microphone (mid 0), pulled a camera (mid 1, which
/// the SFU offered with VP8 as 96), then pushed a video with VP8 preferred
/// (mid 2, VP8 as 100 and its RTX as 101).
library;

String _sdp(List<String> lines) => '${lines.join('\r\n')}\r\n';

/// Our offer for the second push: what the local description holds when
/// the SFU's answer arrives.
final pushAfterPullOffer = _sdp([
  'v=0',
  'o=- 7614363332336792228 4 IN IP4 127.0.0.1',
  's=-',
  't=0 0',
  'a=group:BUNDLE 0 1 2',
  'a=extmap-allow-mixed',
  'm=audio 9 UDP/TLS/RTP/SAVPF 111 0 8',
  'a=mid:0',
  'a=sendonly',
  'a=rtpmap:111 opus/48000/2',
  'a=fmtp:111 minptime=10;useinbandfec=1',
  'a=rtpmap:0 PCMU/8000',
  'a=rtpmap:8 PCMA/8000',
  'm=video 9 UDP/TLS/RTP/SAVPF 125 37 96 35',
  'a=mid:1',
  'a=recvonly',
  'a=rtpmap:125 H264/90000',
  'a=fmtp:125 level-asymmetry-allowed=1;packetization-mode=1;'
      'profile-level-id=42e034',
  'a=rtpmap:37 rtx/90000',
  'a=fmtp:37 apt=125',
  'a=rtpmap:96 VP8/90000',
  'a=rtpmap:35 rtx/90000',
  'a=fmtp:35 apt=96',
  'm=video 9 UDP/TLS/RTP/SAVPF 100 101 109 114 115',
  'a=mid:2',
  'a=sendonly',
  'a=rtpmap:100 VP8/90000',
  'a=rtcp-fb:100 nack',
  'a=rtpmap:101 rtx/90000',
  'a=fmtp:101 apt=100',
  'a=rtpmap:109 red/90000',
  'a=rtpmap:114 rtx/90000',
  'a=fmtp:114 apt=109',
  'a=rtpmap:115 ulpfec/90000',
]);

/// The SFU's answer to [pushAfterPullOffer]: mid 2 has VP8 as 96, the
/// BUNDLE's number for it, but its RTX still says `apt=100`.
final pushAfterPullAnswer = _sdp([
  'v=0',
  'o=- 642999939058727361 1790945585 IN IP4 0.0.0.0',
  's=-',
  't=0 0',
  'a=extmap-allow-mixed',
  'a=group:BUNDLE 0 1 2',
  'm=audio 9 UDP/TLS/RTP/SAVPF 111 0 8',
  'a=mid:0',
  'a=rtpmap:111 opus/48000/2',
  'a=fmtp:111 minptime=10;useinbandfec=1',
  'a=rtpmap:0 PCMU/8000',
  'a=rtpmap:8 PCMA/8000',
  'a=recvonly',
  'm=video 9 UDP/TLS/RTP/SAVPF 125 37 96 35 100 101',
  'a=mid:1',
  'a=rtpmap:125 H264/90000',
  'a=fmtp:125 level-asymmetry-allowed=1;packetization-mode=1;'
      'profile-level-id=42e034',
  'a=rtpmap:37 rtx/90000',
  'a=fmtp:37 apt=125',
  'a=rtpmap:96 VP8/90000',
  'a=rtpmap:35 rtx/90000',
  'a=fmtp:35 apt=96',
  'a=rtpmap:100 VP8/90000',
  'a=rtpmap:101 rtx/90000',
  'a=fmtp:101 apt=100',
  'a=sendonly',
  'm=video 9 UDP/TLS/RTP/SAVPF 96 101',
  'a=mid:2',
  'a=rtpmap:96 VP8/90000',
  'a=rtpmap:101 rtx/90000',
  'a=fmtp:101 apt=100',
  'a=recvonly',
]);

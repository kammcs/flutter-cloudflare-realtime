import 'package:cloudflare_realtime/src/session/sdp_repair.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/sdp_fixtures.dart';

/// The lines of [sdp]'s m-section with [mid] (from its m-line).
List<String> _section(String sdp, String mid) {
  final sections = sdp.split('\r\n').fold<List<List<String>>>([], (all, l) {
    if (l.startsWith('m=')) {
      all.add([l]);
    } else if (all.isNotEmpty && l.isNotEmpty) {
      all.last.add(l);
    }
    return all;
  });
  return sections.firstWhere((s) => s.contains('a=mid:$mid'));
}

String _sdp(List<String> lines) => '${lines.join('\r\n')}\r\n';

void main() {
  group('repairRtxAssociations', () {
    test('points a dangling apt at the codec the answer renumbered', () {
      final repaired = repairRtxAssociations(
        pushAfterPullAnswer,
        localSdp: pushAfterPullOffer,
      );

      expect(_section(repaired, '2'), [
        'm=video 9 UDP/TLS/RTP/SAVPF 96 101',
        'a=mid:2',
        'a=rtpmap:96 VP8/90000',
        'a=rtpmap:101 rtx/90000',
        'a=fmtp:101 apt=96',
        'a=recvonly',
      ]);
      // Everything else, including mid 1's valid apt=100, is untouched.
      expect(
        repaired.replaceFirst('a=fmtp:101 apt=96\r\na=recvonly', ''),
        pushAfterPullAnswer.replaceFirst(
          'a=fmtp:101 apt=100\r\na=recvonly',
          '',
        ),
      );
      expect(repaired, endsWith('a=recvonly\r\n'));
    });

    test('returns valid SDP and opaque text identical', () {
      final valid = repairRtxAssociations(
        pushAfterPullOffer,
        localSdp: pushAfterPullOffer,
      );
      expect(valid, same(pushAfterPullOffer));
      const opaque = 'answer:offer-1';
      expect(repairRtxAssociations(opaque, localSdp: 'offer-1'), same(opaque));
      expect(repairRtxAssociations(opaque), same(opaque));
    });

    test('finds the codec in another local m-section', () {
      // A later SFU offer: our local answer numbered mid 2 differently, but
      // the BUNDLE still says what 100 is.
      final local = _sdp([
        'v=0',
        'm=video 9 UDP/TLS/RTP/SAVPF 100 101',
        'a=mid:1',
        'a=rtpmap:100 VP8/90000',
        'a=rtpmap:101 rtx/90000',
        'a=fmtp:101 apt=100',
      ]);
      final remote = _sdp([
        'v=0',
        'm=video 9 UDP/TLS/RTP/SAVPF 96 101',
        'a=mid:2',
        'a=rtpmap:96 VP8/90000',
        'a=rtpmap:101 rtx/90000',
        'a=fmtp:101 apt=100',
      ]);
      expect(
        _section(repairRtxAssociations(remote, localSdp: local), '2'),
        contains('a=fmtp:101 apt=96'),
      );
    });

    test('prefers the payload type with the same format parameters', () {
      final local = _sdp([
        'v=0',
        'm=video 9 UDP/TLS/RTP/SAVPF 102 103',
        'a=mid:0',
        'a=rtpmap:102 H264/90000',
        'a=fmtp:102 profile-level-id=42e01f;packetization-mode=1',
        'a=rtpmap:103 rtx/90000',
        'a=fmtp:103 apt=102',
      ]);
      final remote = _sdp([
        'v=0',
        'm=video 9 UDP/TLS/RTP/SAVPF 125 127 103',
        'a=mid:0',
        'a=rtpmap:125 H264/90000',
        'a=fmtp:125 packetization-mode=1;profile-level-id=640c1f',
        'a=rtpmap:127 H264/90000',
        'a=fmtp:127 packetization-mode=1;profile-level-id=42e01f',
        'a=rtpmap:103 rtx/90000',
        'a=fmtp:103 apt=102',
      ]);
      expect(
        _section(repairRtxAssociations(remote, localSdp: local), '0'),
        contains('a=fmtp:103 apt=127'),
      );
    });

    test('keeps other format parameters of the RTX line', () {
      final local = _sdp([
        'v=0',
        'm=video 9 UDP/TLS/RTP/SAVPF 100 101',
        'a=mid:0',
        'a=rtpmap:100 VP8/90000',
      ]);
      final remote = _sdp([
        'v=0',
        'm=video 9 UDP/TLS/RTP/SAVPF 96 101',
        'a=mid:0',
        'a=rtpmap:96 VP8/90000',
        'a=rtpmap:101 rtx/90000',
        'a=fmtp:101 rtx-time=3000;apt=100',
      ]);
      expect(
        _section(repairRtxAssociations(remote, localSdp: local), '0'),
        contains('a=fmtp:101 rtx-time=3000;apt=96'),
      );
    });

    test('removes an RTX entry it cannot resolve', () {
      final remote = _sdp([
        'v=0',
        'm=video 9 UDP/TLS/RTP/SAVPF 96 97 101',
        'a=mid:0',
        'a=rtpmap:96 VP8/90000',
        'a=rtpmap:97 rtx/90000',
        'a=fmtp:97 apt=96',
        'a=rtpmap:101 rtx/90000',
        'a=fmtp:101 apt=100',
        'a=rtcp-fb:101 transport-cc',
        'a=recvonly',
      ]);
      final expected = [
        'm=video 9 UDP/TLS/RTP/SAVPF 96 97',
        'a=mid:0',
        'a=rtpmap:96 VP8/90000',
        'a=rtpmap:97 rtx/90000',
        'a=fmtp:97 apt=96',
        'a=recvonly',
      ];
      // No local description says what 100 was.
      expect(_section(repairRtxAssociations(remote), '0'), expected);
      // 100 was VP8, but VP8 already has its own RTX here.
      final local = _sdp([
        'v=0',
        'm=video 9 UDP/TLS/RTP/SAVPF 100',
        'a=mid:0',
        'a=rtpmap:100 VP8/90000',
      ]);
      expect(
        _section(repairRtxAssociations(remote, localSdp: local), '0'),
        expected,
      );
    });

    test('keeps LF line endings', () {
      final remote = pushAfterPullAnswer.replaceAll('\r\n', '\n');
      final local = pushAfterPullOffer.replaceAll('\r\n', '\n');
      final repaired = repairRtxAssociations(remote, localSdp: local);
      expect(repaired, isNot(contains('\r')));
      expect(repaired, contains('a=fmtp:101 apt=96\na=recvonly\n'));
    });
  });
}

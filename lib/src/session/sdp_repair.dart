/// Repairs to the SDP the SFU sends, applied before it reaches the peer
/// connection (`docs/design.md` §4.2).
///
/// Internal: not exported from the package barrel.
library;

/// Returns [remoteSdp] with every RTX `apt` that names a payload type
/// missing from its m-section pointed back at the codec it meant.
///
/// The SFU numbers a codec the way the session's BUNDLE already does: once
/// a session has pulled a video (VP8 offered as 96), its answer to a push
/// that offered VP8 as 100 says 96, but keeps the RTX line as offered
/// (`a=fmtp:101 apt=100`). libwebrtc can't map that RTX entry, so it finds
/// no codec to send with and rejects the whole answer ("Failed to set
/// remote video description send parameters for m-section with mid=...").
///
/// [localSdp], the local description, says which codec a dangling `apt`
/// meant: the payload type's codec in the same m-section, else in any
/// m-section (libwebrtc numbers codecs the same across a BUNDLE). The `apt`
/// is then pointed at the payload type [remoteSdp]'s m-section uses for that
/// codec (preferring identical format parameters). If it has none, or that
/// codec already has its own RTX, the dangling RTX entry is removed, which
/// costs that codec retransmissions instead of the whole m-section.
///
/// Returns [remoteSdp] itself (identical) when nothing dangles, including
/// for text that isn't SDP.
String repairRtxAssociations(String remoteSdp, {String? localSdp}) {
  final remote = _Sdp.parse(remoteSdp);
  final local = localSdp == null ? null : _Sdp.parse(localSdp);
  var changed = false;
  for (final section in remote.sections) {
    for (final (rtx, apt) in section.danglingRtx()) {
      final meant =
          local?.codecInSection(section.mid, apt) ??
          local?.codecAnywhere(apt) ??
          remote.codecAnywhere(apt, except: section);
      final target = meant == null ? null : section.payloadTypeFor(meant);
      if (target != null && !section.hasRtxFor(target)) {
        section.setApt(rtx, target);
      } else {
        section.removePayloadType(rtx);
      }
      changed = true;
    }
  }
  return changed ? remote.render() : remoteSdp;
}

/// A codec as `a=rtpmap` and `a=fmtp` describe it.
class _Codec {
  _Codec(this.encoding, this.parameters);

  /// `name/clock[/channels]`, lowercased.
  final String encoding;

  /// The `a=fmtp` parameters, normalized (sorted, trimmed, lowercased).
  final String parameters;

  bool get isRtx => encoding.startsWith('rtx/');
}

class _Sdp {
  _Sdp(this._head, this.sections, this._eol, this._trailingEol);

  factory _Sdp.parse(String sdp) {
    final eol = sdp.contains('\r\n') ? '\r\n' : '\n';
    final trailing = sdp.endsWith('\n');
    final lines = sdp.split('\n').map((l) => l.replaceAll('\r', '')).toList();
    if (trailing) lines.removeLast();
    final head = <String>[];
    final sections = <_Section>[];
    for (final line in lines) {
      if (line.startsWith('m=')) {
        sections.add(_Section([line]));
      } else if (sections.isEmpty) {
        head.add(line);
      } else {
        sections.last.lines.add(line);
      }
    }
    return _Sdp(head, sections, eol, trailing);
  }

  final List<String> _head;
  final List<_Section> sections;
  final String _eol;
  final bool _trailingEol;

  _Codec? codecInSection(String? mid, int payloadType) {
    if (mid == null) return null;
    for (final section in sections) {
      if (section.mid != mid) continue;
      final codec = section.codec(payloadType);
      return codec != null && !codec.isRtx ? codec : null;
    }
    return null;
  }

  _Codec? codecAnywhere(int payloadType, {_Section? except}) {
    for (final section in sections) {
      if (identical(section, except)) continue;
      final codec = section.codec(payloadType);
      if (codec != null && !codec.isRtx) return codec;
    }
    return null;
  }

  String render() {
    final text = [
      ..._head,
      for (final section in sections) ...section.lines,
    ].join(_eol);
    return _trailingEol ? '$text$_eol' : text;
  }
}

class _Section {
  _Section(this.lines);

  final List<String> lines;

  static final _rtpmap = RegExp(r'^a=rtpmap:(\d+) (.+)$');
  static final _fmtp = RegExp(r'^a=fmtp:(\d+) (.*)$');
  static final _apt = RegExp(r'(^|;)\s*apt=(\d+)');

  String? get mid {
    for (final line in lines) {
      if (line.startsWith('a=mid:')) return line.substring(6).trim();
    }
    return null;
  }

  /// The payload types on the m-line, in order.
  List<int> get payloadTypes {
    final fields = lines.first.split(' ');
    return [for (final f in fields.skip(3)) ?int.tryParse(f)];
  }

  _Codec? codec(int payloadType) {
    String? encoding;
    var parameters = '';
    for (final line in lines) {
      final rtpmap = _rtpmap.firstMatch(line);
      if (rtpmap != null && int.parse(rtpmap[1]!) == payloadType) {
        encoding = rtpmap[2]!.trim().toLowerCase();
      }
      final fmtp = _fmtp.firstMatch(line);
      if (fmtp != null && int.parse(fmtp[1]!) == payloadType) {
        parameters = _normalize(fmtp[2]!);
      }
    }
    return encoding == null ? null : _Codec(encoding, parameters);
  }

  /// The `(rtx, apt)` pairs whose `apt` isn't on the m-line.
  List<(int, int)> danglingRtx() {
    final present = payloadTypes.toSet();
    final dangling = <(int, int)>[];
    for (final line in lines) {
      final fmtp = _fmtp.firstMatch(line);
      if (fmtp == null) continue;
      final rtx = int.parse(fmtp[1]!);
      final apt = _apt.firstMatch(fmtp[2]!);
      if (apt == null || !present.contains(rtx)) continue;
      final target = int.parse(apt[2]!);
      if (!present.contains(target)) dangling.add((rtx, target));
    }
    return dangling;
  }

  /// The payload type this m-section uses for [codec], preferring identical
  /// format parameters, or `null`.
  int? payloadTypeFor(_Codec codec) {
    int? sameName;
    for (final pt in payloadTypes) {
      final candidate = this.codec(pt);
      if (candidate == null || candidate.encoding != codec.encoding) continue;
      if (candidate.parameters == codec.parameters) return pt;
      sameName ??= pt;
    }
    return sameName;
  }

  bool hasRtxFor(int payloadType) {
    final present = payloadTypes.toSet();
    for (final line in lines) {
      final fmtp = _fmtp.firstMatch(line);
      if (fmtp == null || !present.contains(int.parse(fmtp[1]!))) continue;
      final apt = _apt.firstMatch(fmtp[2]!);
      if (apt != null && int.parse(apt[2]!) == payloadType) return true;
    }
    return false;
  }

  void setApt(int rtx, int target) {
    for (var i = 0; i < lines.length; i++) {
      final fmtp = _fmtp.firstMatch(lines[i]);
      if (fmtp == null || int.parse(fmtp[1]!) != rtx) continue;
      final parameters = fmtp[2]!.replaceFirstMapped(
        _apt,
        (m) => '${m[1]}apt=$target',
      );
      lines[i] = 'a=fmtp:$rtx $parameters';
    }
  }

  void removePayloadType(int payloadType) {
    final fields = lines.first.split(' ');
    lines[0] = [
      ...fields.take(3),
      ...fields.skip(3).where((f) => f != '$payloadType'),
    ].join(' ');
    final prefixes = [
      'a=rtpmap:$payloadType ',
      'a=fmtp:$payloadType ',
      'a=rtcp-fb:$payloadType ',
    ];
    lines.removeWhere((line) => prefixes.any(line.startsWith));
  }

  static String _normalize(String parameters) {
    final parts = [
      for (final p in parameters.split(';'))
        if (p.trim().isNotEmpty) p.trim().toLowerCase(),
    ]..sort();
    return parts.join(';');
  }
}

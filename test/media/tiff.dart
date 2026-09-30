import 'dart:typed_data';

/// Builds a baseline, uncompressed TIFF with 8-bit samples, like the
/// thumbnails `flutter_webrtc` sends on macOS (`NSImage.TIFFRepresentation`).
///
/// [pixels] holds [samples] bytes per pixel, row by row. [compression] is
/// only written to the header (the data stays raw).
Uint8List buildTiff({
  required int width,
  required int height,
  required int samples,
  required List<int> pixels,
  int? photometric,
  bool bigEndian = false,
  int compression = 1,
  int? rowsPerStrip,
}) {
  final endian = bigEndian ? Endian.big : Endian.little;
  final rows = rowsPerStrip ?? height;
  final strips = (height + rows - 1) ~/ rows;
  const entryCount = 9;
  const ifd = 8;
  const ifdSize = 2 + entryCount * 12 + 4;
  final bitsAt = ifd + ifdSize;
  final offsetsAt = bitsAt + samples * 2;
  final countsAt = offsetsAt + strips * 4;
  final dataAt = countsAt + strips * 4;
  final data = ByteData(dataAt + pixels.length);
  final bytes = data.buffer.asUint8List();

  bytes[0] = bigEndian ? 0x4d : 0x49;
  bytes[1] = bigEndian ? 0x4d : 0x49;
  data.setUint16(2, 42, endian);
  data.setUint32(4, ifd, endian);
  data.setUint16(ifd, entryCount, endian);

  var entry = ifd + 2;
  void put(int tag, int type, int count, int value) {
    data.setUint16(entry, tag, endian);
    data.setUint16(entry + 2, type, endian);
    data.setUint32(entry + 4, count, endian);
    if (type == 3 && count == 1) {
      data.setUint16(entry + 8, value, endian);
    } else {
      data.setUint32(entry + 8, value, endian);
    }
    entry += 12;
  }

  const short = 3;
  const long = 4;
  put(256, long, 1, width);
  put(257, long, 1, height);
  if (samples <= 2) {
    // Inline: one or two SHORTs.
    data.setUint16(entry, 258, endian);
    data.setUint16(entry + 2, short, endian);
    data.setUint32(entry + 4, samples, endian);
    for (var i = 0; i < samples; i++) {
      data.setUint16(entry + 8 + i * 2, 8, endian);
    }
    entry += 12;
  } else {
    put(258, short, samples, bitsAt);
  }
  put(259, short, 1, compression);
  put(262, short, 1, photometric ?? (samples >= 3 ? 2 : 1));
  put(273, long, strips, strips == 1 ? dataAt : offsetsAt);
  put(277, short, 1, samples);
  put(278, long, 1, rows);
  final stripBytes = rows * width * samples;
  put(279, long, strips, strips == 1 ? pixels.length : countsAt);
  data.setUint32(entry, 0, endian); // No next IFD.

  for (var i = 0; i < samples; i++) {
    data.setUint16(bitsAt + i * 2, 8, endian);
  }
  for (var s = 0; s < strips; s++) {
    data.setUint32(offsetsAt + s * 4, dataAt + s * stripBytes, endian);
    final remaining = pixels.length - s * stripBytes;
    data.setUint32(
      countsAt + s * 4,
      remaining < stripBytes ? remaining : stripBytes,
      endian,
    );
  }
  bytes.setAll(dataAt, pixels);
  return bytes;
}

/// A [width]×[height] RGB TIFF filled with [rgb].
Uint8List solidTiff(int width, int height, {required (int, int, int) rgb}) =>
    buildTiff(
      width: width,
      height: height,
      samples: 3,
      pixels: [
        for (var i = 0; i < width * height; i++) ...[rgb.$1, rgb.$2, rgb.$3],
      ],
    );

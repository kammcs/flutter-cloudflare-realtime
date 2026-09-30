/// @docImport 'screen_source_picker.dart';
library;

import 'dart:typed_data';

/// Whether a desktop source thumbnail is blank: `true` when it is empty or
/// every sampled pixel is (nearly) black or transparent, `false` when it
/// shows something, and `null` when this can't tell.
///
/// Used by [ScreenSourcePicker] on macOS, where a missing Screen Recording
/// permission shows up as empty or black thumbnails. `flutter_webrtc` sends
/// macOS thumbnails as TIFF (`NSImage.TIFFRepresentation`), which Flutter's
/// image codecs don't read, so this reads uncompressed 8-bit TIFF itself.
/// Any other format (PNG, JPEG, compressed TIFF) returns `null`.
///
/// A grid of at most 64×64 pixels, spread evenly, is checked. A pixel
/// counts as black when it is transparent or each color channel is at most
/// [threshold].
///
/// Internal: not exported from the package barrel.
bool? thumbnailLooksBlank(Uint8List bytes, {int threshold = 16}) {
  if (bytes.isEmpty) return true;
  final tiff = _Tiff.parse(bytes);
  if (tiff == null) return null;
  final columns = tiff.width < 64 ? tiff.width : 64;
  final rows = tiff.height < 64 ? tiff.height : 64;
  for (var r = 0; r < rows; r++) {
    final y = r * tiff.height ~/ rows;
    for (var c = 0; c < columns; c++) {
      final x = c * tiff.width ~/ columns;
      final pixel = tiff.pixel(x, y);
      if (pixel == null) return null;
      if (!pixel.isBlack(threshold)) return false;
    }
  }
  return true;
}

typedef _Pixel = ({int r, int g, int b, int a});

extension on _Pixel {
  bool isBlack(int threshold) =>
      a == 0 || (r <= threshold && g <= threshold && b <= threshold);
}

/// The parts of a baseline, uncompressed, chunky 8-bit TIFF needed to read
/// pixels.
class _Tiff {
  _Tiff._({
    required this.bytes,
    required this.width,
    required this.height,
    required this.samplesPerPixel,
    required this.grayscale,
    required this.hasAlpha,
    required this.rowsPerStrip,
    required this.stripOffsets,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final int samplesPerPixel;
  final bool grayscale;
  final bool hasAlpha;
  final int rowsPerStrip;
  final List<int> stripOffsets;

  static const _imageWidth = 256;
  static const _imageLength = 257;
  static const _bitsPerSample = 258;
  static const _compression = 259;
  static const _photometric = 262;
  static const _stripOffsets = 273;
  static const _samplesPerPixel = 277;
  static const _rowsPerStrip = 278;
  static const _planarConfiguration = 284;

  static _Tiff? parse(Uint8List bytes) {
    if (bytes.length < 8) return null;
    final Endian endian;
    if (bytes[0] == 0x49 && bytes[1] == 0x49) {
      endian = Endian.little;
    } else if (bytes[0] == 0x4d && bytes[1] == 0x4d) {
      endian = Endian.big;
    } else {
      return null;
    }
    final data = ByteData.sublistView(bytes);
    if (data.getUint16(2, endian) != 42) return null;
    final ifd = data.getUint32(4, endian);
    if (ifd + 2 > bytes.length) return null;
    final count = data.getUint16(ifd, endian);
    if (ifd + 2 + count * 12 > bytes.length) return null;

    final tags = <int, List<int>>{};
    for (var i = 0; i < count; i++) {
      final entry = ifd + 2 + i * 12;
      final tag = data.getUint16(entry, endian);
      final type = data.getUint16(entry + 2, endian);
      final n = data.getUint32(entry + 4, endian);
      final size = switch (type) {
        3 => 2, // SHORT
        4 => 4, // LONG
        _ => 0,
      };
      if (size == 0 || n == 0) continue;
      final inline = size * n <= 4;
      final start = inline ? entry + 8 : data.getUint32(entry + 8, endian);
      if (start + size * n > bytes.length) return null;
      tags[tag] = [
        for (var k = 0; k < n; k++)
          size == 2
              ? data.getUint16(start + k * 2, endian)
              : data.getUint32(start + k * 4, endian),
      ];
    }

    int? single(int tag) => tags[tag]?.first;
    final width = single(_imageWidth);
    final height = single(_imageLength);
    final offsets = tags[_stripOffsets];
    if (width == null || height == null || offsets == null) return null;
    if (width == 0 || height == 0) return null;
    if ((single(_compression) ?? 1) != 1) return null;
    if ((single(_planarConfiguration) ?? 1) != 1) return null;
    final bits = tags[_bitsPerSample] ?? const [1];
    if (bits.any((b) => b != 8)) return null;
    final samples = single(_samplesPerPixel) ?? 1;
    final photometric = single(_photometric);
    final bool grayscale;
    if (photometric == 1 && (samples == 1 || samples == 2)) {
      grayscale = true;
    } else if (photometric == 2 && (samples == 3 || samples == 4)) {
      grayscale = false;
    } else {
      return null;
    }
    return _Tiff._(
      bytes: bytes,
      width: width,
      height: height,
      samplesPerPixel: samples,
      grayscale: grayscale,
      hasAlpha: samples == 2 || samples == 4,
      rowsPerStrip: single(_rowsPerStrip) ?? height,
      stripOffsets: offsets,
    );
  }

  /// The pixel at ([x], [y]), or `null` if the file is truncated.
  _Pixel? pixel(int x, int y) {
    final strip = y ~/ rowsPerStrip;
    if (strip >= stripOffsets.length) return null;
    final offset =
        stripOffsets[strip] +
        ((y % rowsPerStrip) * width + x) * samplesPerPixel;
    if (offset + samplesPerPixel > bytes.length) return null;
    if (grayscale) {
      final v = bytes[offset];
      return (r: v, g: v, b: v, a: hasAlpha ? bytes[offset + 1] : 255);
    }
    return (
      r: bytes[offset],
      g: bytes[offset + 1],
      b: bytes[offset + 2],
      a: hasAlpha ? bytes[offset + 3] : 255,
    );
  }
}

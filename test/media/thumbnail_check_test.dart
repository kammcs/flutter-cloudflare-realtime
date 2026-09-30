import 'dart:typed_data';

import 'package:cloudflare_realtime/src/media/thumbnail_check.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tiff.dart';

void main() {
  test('empty bytes are blank', () {
    expect(thumbnailLooksBlank(Uint8List(0)), isTrue);
  });

  test('an all-black RGB TIFF is blank; any light pixel is not', () {
    expect(thumbnailLooksBlank(solidTiff(40, 20, rgb: (0, 0, 0))), isTrue);
    expect(thumbnailLooksBlank(solidTiff(40, 20, rgb: (12, 8, 16))), isTrue);
    expect(
      thumbnailLooksBlank(solidTiff(40, 20, rgb: (200, 200, 200))),
      isFalse,
    );

    // Black, with one light pixel at the origin (always sampled).
    final pixels = List.filled(40 * 20 * 3, 0)..[0] = 255;
    expect(
      thumbnailLooksBlank(
        buildTiff(width: 40, height: 20, samples: 3, pixels: pixels),
      ),
      isFalse,
    );
  });

  test('transparent pixels count as blank', () {
    final pixels = [
      for (var i = 0; i < 16 * 9; i++) ...[255, 255, 255, 0],
    ];
    expect(
      thumbnailLooksBlank(
        buildTiff(width: 16, height: 9, samples: 4, pixels: pixels),
      ),
      isTrue,
    );
  });

  test('reads big-endian, grayscale and multi-strip files', () {
    expect(
      thumbnailLooksBlank(
        buildTiff(
          width: 8,
          height: 8,
          samples: 1,
          photometric: 1,
          pixels: List.filled(64, 3),
          bigEndian: true,
        ),
      ),
      isTrue,
    );
    // The last row (in the second strip) is light.
    final pixels = List.filled(8 * 8 * 3, 0);
    for (var i = 7 * 8 * 3; i < pixels.length; i++) {
      pixels[i] = 180;
    }
    expect(
      thumbnailLooksBlank(
        buildTiff(
          width: 8,
          height: 8,
          samples: 3,
          pixels: pixels,
          rowsPerStrip: 4,
        ),
      ),
      isFalse,
    );
  });

  test('samples large images on a grid', () {
    expect(thumbnailLooksBlank(solidTiff(320, 180, rgb: (0, 0, 0))), isTrue);
    expect(thumbnailLooksBlank(solidTiff(320, 180, rgb: (0, 90, 0))), isFalse);
  });

  test('cannot tell for other formats, compressed or broken files', () {
    // A PNG signature.
    expect(
      thumbnailLooksBlank(
        Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      ),
      isNull,
    );
    expect(
      thumbnailLooksBlank(
        buildTiff(
          width: 4,
          height: 4,
          samples: 3,
          pixels: List.filled(48, 0),
          compression: 5, // LZW
        ),
      ),
      isNull,
    );
    final whole = solidTiff(8, 8, rgb: (0, 0, 0));
    expect(
      thumbnailLooksBlank(Uint8List.sublistView(whole, 0, whole.length - 20)),
      isNull,
    );
    expect(thumbnailLooksBlank(Uint8List.fromList([0x49, 0x49, 42])), isNull);
  });
}

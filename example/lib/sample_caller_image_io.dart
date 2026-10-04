import 'dart:io';

import 'package:flutter/services.dart';

/// The bundled sample picture, copied into the app's temporary directory
/// (`Directory.systemTemp`: the app's own `code_cache` on Android, which the
/// ring screen, in the same process, can read), as a `file:` URI; `null` if
/// that fails. A real app would use its cache directory (path_provider's
/// `getTemporaryDirectory`); the example avoids the dependency.
Future<Uri?> sampleCallerImage() async {
  try {
    final bytes = await rootBundle.load('assets/sample_caller.png');
    final file = File('${Directory.systemTemp.path}/sample_caller.png');
    await file.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      flush: true,
    );
    return file.uri;
  } on Exception {
    return null;
  }
}

// The caller's picture for Simulate incoming call (docs/design.md §4.8, The
// caller's picture). SystemCalls.reportIncomingCall takes a local URI only:
// a real app downloads the caller's picture into its own storage first and
// passes the file's URI; the example copies a bundled PNG into its
// temporary directory. On the web there is no dart:io (and no system call
// UI), so there is no picture.
export 'sample_caller_image_stub.dart'
    if (dart.library.io) 'sample_caller_image_io.dart';

// What the browser does with the package's remote audio: its hidden
// `<audio>` elements (docs/design.md §4.3, Remote audio). Empty off the web.
export 'web_audio_probe_stub.dart'
    if (dart.library.js_interop) 'web_audio_probe_web.dart';

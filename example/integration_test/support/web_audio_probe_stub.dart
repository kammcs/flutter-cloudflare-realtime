import 'web_audio_element.dart';

export 'web_audio_element.dart';

/// No `<audio>` elements off the web.
List<WebAudioElement> remoteAudioElements() => const [];

/// Never a WebKit browser off the web.
bool isWebKitBrowser() => false;

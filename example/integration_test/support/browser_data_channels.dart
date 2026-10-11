// The browser DataChannels the page creates, with their delivery options
// (docs/design.md §9, the web's maxRetransmits). Nothing off the web.
export 'browser_data_channels_stub.dart'
    if (dart.library.js_interop) 'browser_data_channels_web.dart';

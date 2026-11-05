import 'platform_info.dart';

/// Browsers: only that it is the web.
RealtimePlatformInfo readPlatformInfoNow() =>
    const RealtimePlatformInfo(os: 'web');

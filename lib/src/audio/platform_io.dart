import 'dart:io' show Platform;

/// Whether this is Android or iOS.
bool get isPhone => Platform.isAndroid || Platform.isIOS;

/// Whether this is iOS.
bool get isIOS => Platform.isIOS;

/// Whether this is Android.
bool get isAndroid => Platform.isAndroid;

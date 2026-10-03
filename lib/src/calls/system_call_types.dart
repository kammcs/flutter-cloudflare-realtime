/// @docImport 'system_calls.dart';
library;

import 'package:flutter/foundation.dart';

/// What a [CallHandle]'s value is (`docs/design.md` §4.8).
///
/// iOS shows it in Recents and uses it to call back; Android passes it to
/// Telecom as the call's address (`tel:`, `mailto:`, or the app's own
/// scheme for [generic]).
enum CallHandleType {
  /// An app-defined identifier, such as a user ID or a room ID.
  generic,

  /// A phone number.
  phoneNumber,

  /// An email address.
  emailAddress,
}

/// Who a system call is with, as the system records it: the other party's
/// identifier ([value]) and what kind of identifier it is ([type]).
///
/// Show a readable name with `displayName` on the call; the handle is what
/// the system keeps (iOS Recents).
@immutable
class CallHandle {
  /// Creates a handle.
  const CallHandle(this.value, {this.type = CallHandleType.generic});

  /// A phone number handle.
  const CallHandle.phoneNumber(this.value) : type = CallHandleType.phoneNumber;

  /// An email address handle.
  const CallHandle.emailAddress(this.value)
    : type = CallHandleType.emailAddress;

  /// The identifier.
  final String value;

  /// What [value] is.
  final CallHandleType type;

  @override
  bool operator ==(Object other) =>
      other is CallHandle && other.value == value && other.type == type;

  @override
  int get hashCode => Object.hash(value, type);

  @override
  String toString() => 'CallHandle(${type.name}, $value)';
}

/// Where a [SystemCall] is in its life (`docs/design.md` §4.8).
enum SystemCallState {
  /// An incoming call the system is showing (ringing), not answered yet.
  ringing,

  /// An outgoing call the system knows about; the app is setting it up.
  dialing,

  /// An outgoing call the app reported as connecting
  /// ([SystemCall.reportConnecting]).
  connecting,

  /// The call is in progress: answered, or reported connected.
  active,

  /// The call is on hold, by the user or by the system (another call).
  held,

  /// The call is over; see [SystemCall.endReason].
  ended,
}

/// Why a [SystemCall] ended (`docs/design.md` §4.8).
enum SystemCallEndReason {
  /// Ended on this device: by the app, or from the system's call UI (the
  /// lock screen, a headset or car button, a watch).
  local,

  /// An incoming call declined on this device.
  declined,

  /// The other side hung up.
  remoteEnded,

  /// An incoming call was never answered.
  unanswered,

  /// The call failed (for example it couldn't connect, or the system reset
  /// its call service).
  failed,

  /// Answered on another of the user's devices.
  answeredElsewhere,

  /// Declined on another of the user's devices.
  declinedElsewhere,
}

/// What went wrong reporting or changing a system call.
enum SystemCallErrorCode {
  /// The system refused an incoming call: Do Not Disturb, the block list,
  /// or (iOS) a call reported too late.
  filtered,

  /// A call with this ID already exists.
  alreadyExists,

  /// No call with this ID (it ended meanwhile).
  notFound,

  /// The system can't do this here (for example the maximum number of
  /// calls is reached, or another app's call is active).
  unavailable,

  /// Anything else.
  failed,
}

/// Thrown by [SystemCalls] and [SystemCall] when the system refuses a
/// request.
class SystemCallException implements Exception {
  /// Creates the exception.
  const SystemCallException(this.code, [this.message]);

  /// What went wrong.
  final SystemCallErrorCode code;

  /// The platform's message, if any.
  final String? message;

  @override
  String toString() =>
      'SystemCallException(${code.name}${message == null ? '' : ': $message'})';
}

/// How the system presents this app's calls ([SystemCalls.configure]).
///
/// Several settings exist on one platform only; the other ignores them.
@immutable
class SystemCallsOptions {
  /// Creates a configuration.
  const SystemCallsOptions({
    this.supportsVideo = true,
    this.maximumCalls = 1,
    this.supportsHolding = true,
    this.supportsDtmf = false,
    this.includesCallsInRecents = true,
    this.iconTemplateImageName,
    this.ringtoneSound,
  });

  /// Whether calls can be video calls (iOS `supportsVideo`; Android
  /// `CAPABILITY_SUPPORTS_VIDEO_CALLING`). Default `true`.
  final bool supportsVideo;

  /// How many calls may exist at once. Default 1: a second incoming call
  /// while one is active is still reported, and the system asks the user
  /// to end or hold the first. iOS `maximumCallsPerCallGroup`.
  final int maximumCalls;

  /// Whether the system may put the app's calls on hold (iOS
  /// `supportsHolding`; Android `SUPPORTS_SET_INACTIVE`). Default `true`.
  final bool supportsHolding;

  /// Whether the system's call UI shows a keypad, whose presses arrive as
  /// [SystemCallDtmfEvent] (iOS only). Default `false`.
  final bool supportsDtmf;

  /// Whether the system lists the app's calls in Recents (iOS
  /// `includesCallsInRecents`). Default `true`.
  final bool includesCallsInRecents;

  /// The name of a template image in the app's asset catalog, shown on the
  /// call UI's app button (iOS `iconTemplateImageData`; 40×40 pt, alpha
  /// only). `null`: none.
  final String? iconTemplateImageName;

  /// The file name of a sound in the app bundle to ring with (iOS
  /// `ringtoneSound`). `null`: the system ringtone.
  final String? ringtoneSound;

  /// The configuration as the native code reads it.
  Map<String, Object?> toMap() => {
    'supportsVideo': supportsVideo,
    'maximumCalls': maximumCalls,
    'supportsHolding': supportsHolding,
    'supportsDtmf': supportsDtmf,
    'includesCallsInRecents': includesCallsInRecents,
    'iconTemplateImageName': iconTemplateImageName,
    'ringtoneSound': ringtoneSound,
  };

  @override
  bool operator ==(Object other) =>
      other is SystemCallsOptions &&
      other.supportsVideo == supportsVideo &&
      other.maximumCalls == maximumCalls &&
      other.supportsHolding == supportsHolding &&
      other.supportsDtmf == supportsDtmf &&
      other.includesCallsInRecents == includesCallsInRecents &&
      other.iconTemplateImageName == iconTemplateImageName &&
      other.ringtoneSound == ringtoneSound;

  @override
  int get hashCode => Object.hash(
    supportsVideo,
    maximumCalls,
    supportsHolding,
    supportsDtmf,
    includesCallsInRecents,
    iconTemplateImageName,
    ringtoneSound,
  );
}

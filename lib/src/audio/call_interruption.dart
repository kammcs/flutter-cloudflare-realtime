/// @docImport '../room/room.dart';
library;

/// What took a call's audio away (`docs/design.md` §4.7).
///
/// Reported by [Room.audioInterruption] and [RoomAudioInterruptedEvent]. The
/// platforms say different amounts: Android tells a phone call from another
/// app's audio, iOS doesn't say.
enum CallInterruptionReason {
  /// A phone call is ringing or in progress (Android).
  phoneCall,

  /// Another app took the audio focus: a media player, an alarm, the
  /// assistant (Android).
  otherAudio,

  /// The platform doesn't say. On iOS every interruption is reported this
  /// way: a phone call, Siri, an alarm or another app's audio look the same
  /// to the app.
  unknown,

  /// The call's system call is on hold (`docs/design.md` §4.8): the user or
  /// the system (another call, answered with "hold and accept") held it in
  /// CallKit or Telecom. It resumes when the call is taken off hold.
  held,
}

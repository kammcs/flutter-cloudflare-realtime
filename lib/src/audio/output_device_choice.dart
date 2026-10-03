/// Sets one element's output device (`HTMLMediaElement.setSinkId` on the
/// web); completes with an error when the browser refuses it.
typedef SetSinkId<E> = Future<void> Function(E element, String deviceId);

/// The audio output chosen for a set of media elements: the web sink's
/// `<audio>` elements (`docs/design.md` §4.3, Remote audio).
///
/// A choice is kept only once the browser accepted it. A refused one (Safari
/// switches to a non-default device only from a user gesture) throws, and
/// leaves [deviceId] and the elements as they were, like a failed
/// `Helper.selectAudioOutput` on native platforms. Otherwise every element
/// created later would retry the refused device, and fail out of sight.
///
/// Generic over the element so unit tests can check it without a browser.
/// Internal: not exported.
class OutputDeviceChoice<E> {
  /// Creates the choice; [_setSinkId] switches one element.
  OutputDeviceChoice(this._setSinkId);

  final SetSinkId<E> _setSinkId;
  String? _deviceId;

  /// The device the browser last accepted, or `null` (its default) before
  /// any choice was accepted. New elements start on it.
  String? get deviceId => _deviceId;

  /// Moves [elements] to [deviceId], then keeps it as [deviceId].
  ///
  /// With no elements yet, [probe] (an element nothing plays in) is moved
  /// instead, so a refusal still shows now, while the caller's user gesture
  /// is current, rather than on a later element.
  ///
  /// If the browser refuses any element, the ones it already moved go back
  /// to the previous device (best effort), the previous choice is kept and
  /// the browser's error is rethrown.
  Future<void> choose(
    String deviceId,
    List<E> elements, {
    required E Function() probe,
  }) async {
    final targets = elements.isEmpty ? [probe()] : elements;
    final moved = <E>[];
    (Object, StackTrace)? failure;
    // Every call starts synchronously, while the gesture is current.
    await Future.wait([
      for (final element in targets)
        Future.sync(() => _setSinkId(element, deviceId)).then<void>(
          (_) => moved.add(element),
          onError: (Object error, StackTrace stack) {
            failure ??= (error, stack);
          },
        ),
    ]);
    if (failure case (final error, final stack)) {
      final previous = _deviceId ?? '';
      await Future.wait([
        for (final element in moved)
          Future.sync(
            () => _setSinkId(element, previous),
          ).then<void>((_) {}, onError: (Object _) {}),
      ]);
      Error.throwWithStackTrace(error, stack);
    }
    _deviceId = deviceId;
  }
}

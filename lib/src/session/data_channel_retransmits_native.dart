/// Native platforms: [create] as it is. The plugins get `maxRetransmits`
/// through `toMap()` (`_NegotiatedDataChannelInit`).
T withBrowserMaxRetransmits<T>(int? maxRetransmits, T Function() create) =>
    create();

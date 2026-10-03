// Pins the shape of the public API that the 0.1.0 cleanup decided
// (docs/api-review.md): the exception roots are sealed, so apps can switch
// over them exhaustively. These switches have no default case; they stop
// compiling if a root loses `sealed` or gains a subtype.
import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter_test/flutter_test.dart';

String _brokerCase(BrokerException e) => switch (e) {
  BrokerUnauthorizedException() => 'unauthorized',
  BrokerForbiddenException() => 'forbidden',
  SessionGoneException() => 'gone',
  BrokerTimeoutException() => 'timeout',
  BrokerNetworkException() => 'network',
  BrokerProtocolException() => 'protocol',
  BrokerResponseException() => 'response',
};

String _sessionCase(SfuSessionException e) => switch (e) {
  SfuSessionClosedException() => 'closed',
  SfuSessionFailedException() => 'failed',
  SfuInterruptedException() => 'interrupted',
  SfuTrackException() => 'track',
  SfuDataChannelException() => 'dataChannel',
  SfuRequestException() => 'request',
  SfuProtocolException() => 'protocol',
};

String _mediaCase(MediaException e) => switch (e) {
  ScreenCapturePermissionException() => 'screenPermission',
  MediaPermissionDeniedException() => 'permission',
  ScreenShareSetupException() => 'setup',
  DevicesExhaustedException() => 'exhausted',
  MediaCaptureException() => 'capture',
  ScreenSourcesException() => 'sources',
  ScreenSourceNotFoundException() => 'notFound',
};

void main() {
  test('BrokerException is sealed: one case per subtype', () {
    expect(
      _brokerCase(const BrokerUnauthorizedException(operation: 'x')),
      'unauthorized',
    );
    expect(
      _brokerCase(const BrokerTimeoutException(operation: 'x')),
      'timeout',
    );
    expect(
      _brokerCase(
        const BrokerResponseException(operation: 'x', statusCode: 500),
      ),
      'response',
    );
  });

  test('SfuSessionException is sealed: one case per subtype', () {
    expect(_sessionCase(const SfuSessionClosedException()), 'closed');
    expect(_sessionCase(const SfuInterruptedException('moved')), 'interrupted');
    expect(_sessionCase(const SfuProtocolException('no mid')), 'protocol');
    expect(
      _sessionCase(
        const SfuDataChannelException(operation: 'datachannels/new', name: 'a'),
      ),
      'dataChannel',
    );
  });

  test('MediaException is sealed: one case per subtype', () {
    expect(_mediaCase(const MediaCaptureException('no frames')), 'capture');
    expect(
      _mediaCase(const MediaPermissionDeniedException('denied')),
      'permission',
    );
  });
}

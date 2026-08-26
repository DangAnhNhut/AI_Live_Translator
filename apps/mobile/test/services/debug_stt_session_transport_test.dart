import 'package:ai_live_translator_mobile/services/debug_stt_session_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('debug connect becomes ready after the configured delay', () async {
    final transport = DebugSttSessionTransport(
      initialConnectDelay: Duration.zero,
    );

    await transport.connect();

    expect(transport.isConnected, isTrue);
    await transport.dispose();
  });

  test('held reconnect remains pending until explicitly completed', () async {
    final transport = DebugSttSessionTransport(
      initialConnectDelay: Duration.zero,
    );
    await transport.connect();
    transport.configureNextReconnectToWait();
    await transport.simulateUnexpectedDisconnect();

    var completed = false;
    final reconnect = transport.connect().then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);

    expect(completed, isFalse);
    expect(transport.hasPendingReconnect, isTrue);

    transport.completeReconnectSuccessfully();
    await reconnect;

    expect(completed, isTrue);
    expect(transport.isConnected, isTrue);
    await transport.dispose();
  });

  test('configured reconnect failure throws a controlled exception', () async {
    final transport = DebugSttSessionTransport(
      initialConnectDelay: Duration.zero,
    );
    await transport.connect();
    transport.configureReconnectsToFail();
    await transport.simulateUnexpectedDisconnect();

    await expectLater(
      transport.connect(),
      throwsA(
        isA<DebugSttSessionException>().having(
          (error) => error.recoverable,
          'recoverable',
          isTrue,
        ),
      ),
    );

    await transport.dispose();
  });

  test('disconnect releases a held reconnect without reconnecting', () async {
    final transport = DebugSttSessionTransport(
      initialConnectDelay: Duration.zero,
    );
    await transport.connect();
    transport.configureNextReconnectToWait();
    await transport.simulateUnexpectedDisconnect();
    final reconnect = transport.connect();
    await Future<void>.delayed(Duration.zero);
    expect(transport.hasPendingReconnect, isTrue);

    await transport.disconnect();
    await reconnect.timeout(const Duration(milliseconds: 50));

    expect(transport.hasPendingReconnect, isFalse);
    expect(transport.isConnected, isFalse);
    await transport.dispose();
  });

  test('stop releases a held reconnect without leaving pending work', () async {
    final transport = DebugSttSessionTransport(
      initialConnectDelay: Duration.zero,
    );
    await transport.connect();
    transport.configureNextReconnectToWait();
    await transport.simulateUnexpectedDisconnect();
    final reconnect = transport.connect();
    await Future<void>.delayed(Duration.zero);

    await transport.stop();
    await reconnect.timeout(const Duration(milliseconds: 50));

    expect(transport.hasPendingReconnect, isFalse);
    expect(transport.isConnected, isFalse);
    await transport.dispose();
  });

  test('stop clears an unconsumed reconnect failure cycle', () async {
    final transport = DebugSttSessionTransport(
      initialConnectDelay: Duration.zero,
      reconnectFailureAttempts: 3,
    );
    await transport.connect();
    transport.configureReconnectsToFail();
    await transport.simulateUnexpectedDisconnect();
    await expectLater(
      transport.connect(),
      throwsA(isA<DebugSttSessionException>()),
    );

    await transport.stop();
    await transport.connect();

    expect(transport.isConnected, isTrue);
    await transport.dispose();
  });

  test('dispose releases a held reconnect', () async {
    final transport = DebugSttSessionTransport(
      initialConnectDelay: Duration.zero,
    );
    await transport.connect();
    transport.configureNextReconnectToWait();
    await transport.simulateUnexpectedDisconnect();
    final reconnect = transport.connect();
    await Future<void>.delayed(Duration.zero);

    await transport.dispose();
    await reconnect.timeout(const Duration(milliseconds: 50));

    expect(transport.hasPendingReconnect, isFalse);
    expect(transport.isConnected, isFalse);
  });
}

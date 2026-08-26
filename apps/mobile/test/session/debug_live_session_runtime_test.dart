import 'dart:async';

import 'package:ai_live_translator_mobile/services/debug_stt_session_transport.dart';
import 'package:ai_live_translator_mobile/services/microphone_permission_service.dart';
import 'package:ai_live_translator_mobile/session/live_session_controller.dart';
import 'package:ai_live_translator_mobile/session/live_session_state.dart';
import 'package:ai_live_translator_mobile/session/session_timer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeDebugPermissionGateway implements MicrophonePermissionGateway {
  Completer<MicrophonePermissionResult>? pendingRequest;

  @override
  Future<MicrophonePermissionResult> requestPermission() async {
    return pendingRequest?.future ?? MicrophonePermissionResult.granted;
  }

  @override
  Future<bool> openAppSettings() async => true;
}

class FakeDebugClock implements SessionClock {
  Duration value = Duration.zero;

  @override
  Duration get now => value;
}

class FakeDebugTicker implements SessionTicker {
  FakeDebugTicker(this.clock);

  final FakeDebugClock clock;
  VoidCallback? _onTick;

  @override
  void start(VoidCallback onTick) {
    _onTick = onTick;
  }

  @override
  void stop() {
    _onTick = null;
  }

  @override
  void dispose() {
    _onTick = null;
  }

  void advance(Duration duration) {
    clock.value += duration;
    _onTick?.call();
  }
}

Future<void> flushMicrotasks([int count = 8]) async {
  for (var index = 0; index < count; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'debug runtime reaches listening and preserves pause/resume timer',
    () async {
      final permission = FakeDebugPermissionGateway()
        ..pendingRequest = Completer<MicrophonePermissionResult>();
      final transport = DebugSttSessionTransport(
        initialConnectDelay: Duration.zero,
      );
      final clock = FakeDebugClock();
      final ticker = FakeDebugTicker(clock);
      final controller = LiveSessionController(
        permissionGateway: permission,
        transport: transport,
        clock: clock,
        ticker: ticker,
      );
      final visitedStates = <LiveSessionState>[];
      controller.addListener(() => visitedStates.add(controller.state));

      final start = controller.start();
      expect(controller.state, LiveSessionState.permission);
      expect(controller.elapsed, Duration.zero);

      permission.pendingRequest!.complete(MicrophonePermissionResult.granted);
      await start;
      expect(visitedStates, contains(LiveSessionState.connecting));
      expect(controller.state, LiveSessionState.listening);

      ticker.advance(const Duration(seconds: 3));
      controller.pause();
      ticker.advance(const Duration(seconds: 5));
      expect(controller.state, LiveSessionState.paused);
      expect(controller.elapsed, const Duration(seconds: 3));

      controller.resume();
      ticker.advance(const Duration(seconds: 2));
      expect(controller.state, LiveSessionState.listening);
      expect(controller.elapsed, const Duration(seconds: 5));

      await controller.stop();
      expect(controller.state, LiveSessionState.ready);
      expect(controller.elapsed, Duration.zero);
      controller.dispose();
      await flushMicrotasks();
      await transport.dispose();
    },
  );

  test('held debug reconnect preserves timer and resumes listening', () async {
    final transport = DebugSttSessionTransport(
      initialConnectDelay: Duration.zero,
    );
    final clock = FakeDebugClock();
    final ticker = FakeDebugTicker(clock);
    final controller = LiveSessionController(
      permissionGateway: FakeDebugPermissionGateway(),
      transport: transport,
      clock: clock,
      ticker: ticker,
    );
    await controller.start();
    ticker.advance(const Duration(seconds: 4));

    transport.configureNextReconnectToWait();
    await transport.simulateUnexpectedDisconnect();
    await flushMicrotasks();

    expect(controller.state, LiveSessionState.reconnecting);
    expect(transport.hasPendingReconnect, isTrue);
    ticker.advance(const Duration(seconds: 5));
    expect(controller.elapsed, const Duration(seconds: 4));

    transport.completeReconnectSuccessfully();
    await flushMicrotasks();
    expect(controller.state, LiveSessionState.listening);
    ticker.advance(const Duration(seconds: 2));
    expect(controller.elapsed, const Duration(seconds: 6));

    await controller.stop();
    expect(controller.state, LiveSessionState.ready);
    expect(controller.elapsed, Duration.zero);
    controller.dispose();
    await flushMicrotasks();
    await transport.dispose();
  });

  test(
    'debug reconnect failure retry preserves and resumes elapsed time',
    () async {
      final transport = DebugSttSessionTransport(
        initialConnectDelay: Duration.zero,
        reconnectFailureAttempts: 2,
      );
      final clock = FakeDebugClock();
      final ticker = FakeDebugTicker(clock);
      final controller = LiveSessionController(
        permissionGateway: FakeDebugPermissionGateway(),
        transport: transport,
        clock: clock,
        ticker: ticker,
        maxReconnectAttempts: 2,
        retryDelay: (_) async {},
      );
      await controller.start();
      ticker.advance(const Duration(seconds: 4));

      transport.configureReconnectsToFail();
      await transport.simulateUnexpectedDisconnect();
      await flushMicrotasks();

      expect(controller.state, LiveSessionState.error);
      expect(
        controller.errorMessage,
        'Unable to reconnect to the STT session.',
      );
      expect(controller.elapsed, const Duration(seconds: 4));

      final retryStates = <LiveSessionState>[];
      controller.addListener(() => retryStates.add(controller.state));
      final retry = controller.retry();
      expect(controller.state, LiveSessionState.reconnecting);
      expect(controller.elapsed, const Duration(seconds: 4));
      await retry;

      expect(retryStates, <LiveSessionState>[
        LiveSessionState.reconnecting,
        LiveSessionState.listening,
      ]);
      expect(controller.state, LiveSessionState.listening);
      expect(controller.elapsed, const Duration(seconds: 4));
      ticker.advance(const Duration(seconds: 2));
      expect(controller.elapsed, const Duration(seconds: 6));

      await controller.stop();
      expect(controller.state, LiveSessionState.ready);
      expect(controller.elapsed, Duration.zero);
      controller.dispose();
      await flushMicrotasks();
      await transport.dispose();
    },
  );

  test('stop cancels a held debug reconnect and returns ready', () async {
    final transport = DebugSttSessionTransport(
      initialConnectDelay: Duration.zero,
    );
    final controller = LiveSessionController(
      permissionGateway: FakeDebugPermissionGateway(),
      transport: transport,
    );
    await controller.start();
    transport.configureNextReconnectToWait();
    await transport.simulateUnexpectedDisconnect();
    await flushMicrotasks();
    expect(controller.state, LiveSessionState.reconnecting);
    expect(transport.hasPendingReconnect, isTrue);

    await controller.stop();

    expect(controller.state, LiveSessionState.ready);
    expect(controller.elapsed, Duration.zero);
    expect(transport.hasPendingReconnect, isFalse);
    controller.dispose();
    await flushMicrotasks();
    await transport.dispose();
  });

  test(
    'stop during debug reconnect failures clears the next fresh start',
    () async {
      final retryDelay = Completer<void>();
      final transport = DebugSttSessionTransport(
        initialConnectDelay: Duration.zero,
        reconnectFailureAttempts: 3,
      );
      final controller = LiveSessionController(
        permissionGateway: FakeDebugPermissionGateway(),
        transport: transport,
        maxReconnectAttempts: 3,
        retryDelay: (_) => retryDelay.future,
      );
      await controller.start();

      transport.configureReconnectsToFail();
      await transport.simulateUnexpectedDisconnect();
      await flushMicrotasks();
      expect(controller.state, LiveSessionState.reconnecting);

      await controller.stop();
      retryDelay.complete();
      await flushMicrotasks();
      expect(controller.state, LiveSessionState.ready);

      await controller.start();

      expect(controller.state, LiveSessionState.listening);
      controller.dispose();
      await flushMicrotasks();
      await transport.dispose();
    },
  );
}

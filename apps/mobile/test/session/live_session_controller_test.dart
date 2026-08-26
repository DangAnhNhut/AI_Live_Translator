import 'dart:async';

import 'package:ai_live_translator_mobile/services/microphone_permission_service.dart';
import 'package:ai_live_translator_mobile/services/stt_websocket_service.dart';
import 'package:ai_live_translator_mobile/session/live_session_controller.dart';
import 'package:ai_live_translator_mobile/session/live_session_state.dart';
import 'package:ai_live_translator_mobile/session/session_timer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeMicrophonePermissionGateway implements MicrophonePermissionGateway {
  Completer<MicrophonePermissionResult>? pendingRequest;
  MicrophonePermissionResult result = MicrophonePermissionResult.granted;
  Object? requestError;
  int requestCalls = 0;
  int openSettingsCalls = 0;

  @override
  Future<MicrophonePermissionResult> requestPermission() async {
    requestCalls++;
    if (requestError != null) {
      throw requestError!;
    }
    if (pendingRequest != null) {
      return pendingRequest!.future;
    }
    return result;
  }

  @override
  Future<bool> openAppSettings() async {
    openSettingsCalls++;
    return true;
  }
}

class FakeSttSessionTransport implements SttSessionTransport {
  Completer<void>? pendingConnect;
  Completer<void>? pendingDisconnect;
  Object? connectError;
  int connectCalls = 0;
  int stopCalls = 0;
  int disconnectCalls = 0;
  final List<Future<void>> connectResults = [];
  final StreamController<SttSessionEvent> eventController =
      StreamController<SttSessionEvent>.broadcast();

  @override
  Stream<SttSessionEvent> get events => eventController.stream;

  @override
  Future<void> connect() async {
    connectCalls++;
    if (connectResults.isNotEmpty) {
      await connectResults.removeAt(0);
    }
    await pendingConnect?.future;
    if (connectError != null) {
      throw connectError!;
    }
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    await pendingDisconnect?.future;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

class FakeSessionClock implements SessionClock {
  Duration value = Duration.zero;

  @override
  Duration get now => value;
}

class FakeSessionTicker implements SessionTicker {
  FakeSessionTicker(this.clock);

  final FakeSessionClock clock;
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

void main() {
  test('new session is ready with zero elapsed time', () {
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: FakeSttSessionTransport(),
    );

    expect(controller.state, LiveSessionState.ready);
    expect(controller.elapsed, Duration.zero);

    controller.dispose();
  });

  test('start exposes permission state while request is pending', () {
    final permissionGateway = FakeMicrophonePermissionGateway()
      ..pendingRequest = Completer<MicrophonePermissionResult>();
    final controller = LiveSessionController(
      permissionGateway: permissionGateway,
      transport: FakeSttSessionTransport(),
    );

    unawaited(controller.start());

    expect(controller.state, LiveSessionState.permission);

    controller.dispose();
  });

  test(
    'granted permission advances to connecting until transport is ready',
    () async {
      final transport = FakeSttSessionTransport()
        ..pendingConnect = Completer<void>();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
      );

      unawaited(controller.start());
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, LiveSessionState.connecting);

      controller.dispose();
    },
  );

  test('transport readiness advances connecting to listening', () async {
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: FakeSttSessionTransport(),
    );

    await controller.start();

    expect(controller.state, LiveSessionState.listening);

    controller.dispose();
  });

  test('denied microphone permission exposes a useful error', () async {
    final permissionGateway = FakeMicrophonePermissionGateway()
      ..result = MicrophonePermissionResult.denied;
    final controller = LiveSessionController(
      permissionGateway: permissionGateway,
      transport: FakeSttSessionTransport(),
    );

    await controller.start();

    expect(controller.state, LiveSessionState.error);
    expect(
      controller.errorMessage,
      'Microphone permission is required to start a live session.',
    );

    controller.dispose();
  });

  test('permanently denied permission exposes app settings action', () async {
    final permissionGateway = FakeMicrophonePermissionGateway()
      ..result = MicrophonePermissionResult.permanentlyDenied;
    final controller = LiveSessionController(
      permissionGateway: permissionGateway,
      transport: FakeSttSessionTransport(),
    );

    await controller.start();

    expect(controller.state, LiveSessionState.error);
    expect(controller.canOpenAppSettings, isTrue);
    await controller.openAppSettings();
    expect(permissionGateway.openSettingsCalls, 1);

    controller.dispose();
  });

  test('connection failure becomes an actionable error state', () async {
    final transport = FakeSttSessionTransport()
      ..connectError = Exception('connection refused');
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
    );

    await controller.start();

    expect(controller.state, LiveSessionState.error);
    expect(
      controller.errorMessage,
      'WebSocket connection failed. Check that the backend is available.',
    );

    controller.dispose();
  });

  test('normalized provider error is preserved for the user', () async {
    final transport = FakeSttSessionTransport()
      ..connectError = const SttSessionException(
        code: 'provider_unavailable',
        message: 'STT provider is unavailable.',
        recoverable: false,
      );
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
    );

    await controller.start();

    expect(controller.state, LiveSessionState.error);
    expect(controller.errorMessage, 'STT provider is unavailable.');

    controller.dispose();
  });

  test('duplicate start does not create concurrent connections', () async {
    final transport = FakeSttSessionTransport()
      ..pendingConnect = Completer<void>();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
    );

    unawaited(controller.start());
    await Future<void>.delayed(Duration.zero);
    unawaited(controller.start());
    await Future<void>.delayed(Duration.zero);

    expect(transport.connectCalls, 1);

    controller.dispose();
  });

  test('elapsed time advances while listening', () async {
    final clock = FakeSessionClock();
    final ticker = FakeSessionTicker(clock);
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: FakeSttSessionTransport(),
      clock: clock,
      ticker: ticker,
    );

    await controller.start();
    ticker.advance(const Duration(seconds: 3));

    expect(controller.elapsed, const Duration(seconds: 3));

    controller.dispose();
  });

  test('pause freezes elapsed time without resetting the session', () async {
    final clock = FakeSessionClock();
    final ticker = FakeSessionTicker(clock);
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: FakeSttSessionTransport(),
      clock: clock,
      ticker: ticker,
    );
    await controller.start();
    ticker.advance(const Duration(seconds: 3));

    controller.pause();
    ticker.advance(const Duration(seconds: 5));

    expect(controller.state, LiveSessionState.paused);
    expect(controller.elapsed, const Duration(seconds: 3));

    controller.dispose();
  });

  test('resume continues elapsed time from the paused duration', () async {
    final clock = FakeSessionClock();
    final ticker = FakeSessionTicker(clock);
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: FakeSttSessionTransport(),
      clock: clock,
      ticker: ticker,
    );
    await controller.start();
    ticker.advance(const Duration(seconds: 3));
    controller.pause();
    ticker.advance(const Duration(seconds: 5));

    controller.resume();
    ticker.advance(const Duration(seconds: 2));

    expect(controller.state, LiveSessionState.listening);
    expect(controller.elapsed, const Duration(seconds: 5));

    controller.dispose();
  });

  test('stop from listening cleans up and resets to ready', () async {
    final clock = FakeSessionClock();
    final ticker = FakeSessionTicker(clock);
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      clock: clock,
      ticker: ticker,
    );
    await controller.start();
    ticker.advance(const Duration(seconds: 4));

    await controller.stop();

    expect(controller.state, LiveSessionState.ready);
    expect(controller.elapsed, Duration.zero);
    expect(transport.stopCalls, 1);
    expect(transport.disconnectCalls, 1);
    expect(controller.errorMessage, isNull);

    controller.dispose();
  });

  test('overlapping stop calls share one delayed cleanup', () async {
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
    );
    await controller.start();
    transport.pendingDisconnect = Completer<void>();

    final firstStop = controller.stop();
    await Future<void>.delayed(Duration.zero);
    final secondStop = controller.stop();
    await Future<void>.delayed(Duration.zero);

    expect(transport.stopCalls, 1);
    expect(transport.disconnectCalls, 1);

    transport.pendingDisconnect!.complete();
    await Future.wait([firstStop, secondStop]);
    expect(controller.state, LiveSessionState.ready);

    controller.dispose();
    await transport.eventController.close();
  });

  test(
    'normalized transcript events update visible transcript state',
    () async {
      final transport = FakeSttSessionTransport();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
      );
      await controller.start();

      transport.eventController.add(
        const SttTranscriptEvent(
          kind: SttTranscriptKind.finalResult,
          segmentId: 'segment-1',
          text: 'Xin chao',
          language: 'vi',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.transcript, 'Xin chao');

      controller.dispose();
      await transport.eventController.close();
    },
  );

  test(
    'unexpected close enters reconnecting and preserves elapsed time',
    () async {
      final clock = FakeSessionClock();
      final ticker = FakeSessionTicker(clock);
      final reconnectReady = Completer<void>();
      final transport = FakeSttSessionTransport()
        ..connectResults.addAll([Future<void>.value(), reconnectReady.future]);
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        clock: clock,
        ticker: ticker,
      );
      await controller.start();
      ticker.advance(const Duration(seconds: 4));

      transport.eventController.add(
        const SttSessionClosedEvent(unexpected: true),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, LiveSessionState.reconnecting);
      expect(controller.elapsed, const Duration(seconds: 4));
      expect(transport.connectCalls, 2);

      controller.dispose();
      await transport.eventController.close();
    },
  );

  test(
    'unexpected close while paused reconnects back to paused with frozen time',
    () async {
      final clock = FakeSessionClock();
      final ticker = FakeSessionTicker(clock);
      final reconnectReady = Completer<void>();
      final transport = FakeSttSessionTransport()
        ..connectResults.addAll([Future<void>.value(), reconnectReady.future]);
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        clock: clock,
        ticker: ticker,
      );
      await controller.start();
      ticker.advance(const Duration(seconds: 4));
      controller.pause();

      transport.eventController.add(
        const SttSessionClosedEvent(unexpected: true),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, LiveSessionState.reconnecting);
      ticker.advance(const Duration(seconds: 3));
      expect(controller.elapsed, const Duration(seconds: 4));

      reconnectReady.complete();
      await Future<void>.delayed(Duration.zero);
      expect(controller.state, LiveSessionState.paused);
      ticker.advance(const Duration(seconds: 2));
      expect(controller.elapsed, const Duration(seconds: 4));

      controller.dispose();
      await transport.eventController.close();
    },
  );

  test(
    'paused reconnect exhaustion retries back to paused with frozen time',
    () async {
      final clock = FakeSessionClock();
      final ticker = FakeSessionTicker(clock);
      final transport = FakeSttSessionTransport();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        clock: clock,
        ticker: ticker,
        maxReconnectAttempts: 2,
        retryDelay: (_) async {},
      );
      await controller.start();
      ticker.advance(const Duration(seconds: 4));
      controller.pause();
      transport.connectError = Exception('backend unavailable');

      transport.eventController.add(
        const SttSessionClosedEvent(unexpected: true),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, LiveSessionState.error);
      expect(controller.elapsed, const Duration(seconds: 4));
      transport.connectError = null;

      final retryFuture = controller.retry();
      expect(controller.state, LiveSessionState.reconnecting);
      await retryFuture;

      expect(controller.state, LiveSessionState.paused);
      ticker.advance(const Duration(seconds: 2));
      expect(controller.elapsed, const Duration(seconds: 4));

      controller.dispose();
      await transport.eventController.close();
    },
  );

  test('normalized STT error while paused enters error', () async {
    final clock = FakeSessionClock();
    final ticker = FakeSessionTicker(clock);
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      clock: clock,
      ticker: ticker,
    );
    await controller.start();
    ticker.advance(const Duration(seconds: 4));
    controller.pause();

    transport.eventController.add(
      const SttSessionErrorEvent(
        code: 'provider_unavailable',
        message: 'STT provider is unavailable.',
        recoverable: false,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, LiveSessionState.error);
    expect(controller.elapsed, const Duration(seconds: 4));

    controller.dispose();
    await transport.eventController.close();
  });

  test(
    'reconnect exhaustion transitions to error after bounded attempts',
    () async {
      final clock = FakeSessionClock();
      final ticker = FakeSessionTicker(clock);
      final transport = FakeSttSessionTransport();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        clock: clock,
        ticker: ticker,
        maxReconnectAttempts: 2,
        retryDelay: (_) async {},
      );
      await controller.start();
      ticker.advance(const Duration(seconds: 4));
      transport.connectError = Exception('backend unavailable');

      transport.eventController.add(
        const SttSessionClosedEvent(unexpected: true),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, LiveSessionState.error);
      expect(
        controller.errorMessage,
        'Unable to reconnect to the STT session.',
      );
      expect(controller.elapsed, const Duration(seconds: 4));
      expect(transport.connectCalls, 3);

      await controller.stop();
      expect(controller.state, LiveSessionState.ready);
      expect(controller.elapsed, Duration.zero);

      controller.dispose();
      await transport.eventController.close();
    },
  );

  test(
    'successful reconnect resumes listening timer from preserved time',
    () async {
      final clock = FakeSessionClock();
      final ticker = FakeSessionTicker(clock);
      final reconnectReady = Completer<void>();
      final transport = FakeSttSessionTransport()
        ..connectResults.addAll([Future<void>.value(), reconnectReady.future]);
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        clock: clock,
        ticker: ticker,
      );
      await controller.start();
      ticker.advance(const Duration(seconds: 4));
      transport.eventController.add(
        const SttSessionClosedEvent(unexpected: true),
      );
      await Future<void>.delayed(Duration.zero);
      clock.value += const Duration(seconds: 5);

      reconnectReady.complete();
      await Future<void>.delayed(Duration.zero);
      ticker.advance(const Duration(seconds: 2));

      expect(controller.state, LiveSessionState.listening);
      expect(controller.elapsed, const Duration(seconds: 6));

      controller.dispose();
      await transport.eventController.close();
    },
  );

  test(
    'retry after reconnect exhaustion preserves and resumes elapsed time',
    () async {
      final clock = FakeSessionClock();
      final ticker = FakeSessionTicker(clock);
      final transport = FakeSttSessionTransport();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        clock: clock,
        ticker: ticker,
        maxReconnectAttempts: 2,
        retryDelay: (_) async {},
      );
      await controller.start();
      ticker.advance(const Duration(seconds: 4));
      transport.connectError = Exception('backend unavailable');
      transport.eventController.add(
        const SttSessionClosedEvent(unexpected: true),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(controller.state, LiveSessionState.error);
      expect(controller.elapsed, const Duration(seconds: 4));
      transport.connectError = null;

      await controller.retry();

      expect(controller.state, LiveSessionState.listening);
      expect(controller.elapsed, const Duration(seconds: 4));
      ticker.advance(const Duration(seconds: 2));
      expect(controller.elapsed, const Duration(seconds: 6));
      controller.dispose();
      await transport.eventController.close();
    },
  );

  test('retry after active transport error uses reconnect semantics', () async {
    final permissionGateway = FakeMicrophonePermissionGateway();
    final clock = FakeSessionClock();
    final ticker = FakeSessionTicker(clock);
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: permissionGateway,
      transport: transport,
      clock: clock,
      ticker: ticker,
    );
    await controller.start();
    ticker.advance(const Duration(seconds: 4));
    transport.eventController.add(
      const SttTranscriptEvent(
        kind: SttTranscriptKind.finalResult,
        segmentId: 'segment-1',
        text: 'Existing session transcript',
        language: 'vi',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    transport.eventController.add(
      const SttSessionErrorEvent(
        code: 'temporary_transport_error',
        message: 'Temporary transport error.',
        recoverable: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, LiveSessionState.error);
    final retryStates = <LiveSessionState>[];
    controller.addListener(() => retryStates.add(controller.state));

    await controller.retry();

    expect(retryStates, <LiveSessionState>[
      LiveSessionState.reconnecting,
      LiveSessionState.listening,
    ]);
    expect(permissionGateway.requestCalls, 1);
    expect(controller.transcript, 'Existing session transcript');
    expect(controller.elapsed, const Duration(seconds: 4));
    controller.dispose();
    await transport.eventController.close();
  });

  test(
    'normalized STT error while listening enters error and freezes timer',
    () async {
      final clock = FakeSessionClock();
      final ticker = FakeSessionTicker(clock);
      final transport = FakeSttSessionTransport();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        clock: clock,
        ticker: ticker,
      );
      await controller.start();
      ticker.advance(const Duration(seconds: 4));

      transport.eventController.add(
        const SttSessionErrorEvent(
          code: 'provider_unavailable',
          message: 'STT provider is unavailable.',
          recoverable: false,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      ticker.advance(const Duration(seconds: 3));

      expect(controller.state, LiveSessionState.error);
      expect(controller.errorMessage, 'STT provider is unavailable.');
      expect(controller.elapsed, const Duration(seconds: 4));

      controller.dispose();
      await transport.eventController.close();
    },
  );

  test('stop while connecting ignores stale transport readiness', () async {
    final connectReady = Completer<void>();
    final transport = FakeSttSessionTransport()..pendingConnect = connectReady;
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
    );

    final startFuture = controller.start();
    await Future<void>.delayed(Duration.zero);
    await controller.stop();
    connectReady.complete();
    await startFuture;

    expect(controller.state, LiveSessionState.ready);
    expect(controller.elapsed, Duration.zero);
    expect(transport.disconnectCalls, 1);

    controller.dispose();
    await transport.eventController.close();
  });

  test('stop from paused resets to ready', () async {
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
    );
    await controller.start();
    controller.pause();

    await controller.stop();

    expect(controller.state, LiveSessionState.ready);
    expect(controller.elapsed, Duration.zero);
    expect(transport.stopCalls, 1);
    expect(transport.disconnectCalls, 1);
    controller.dispose();
    await transport.eventController.close();
  });

  test('stop from reconnecting cancels retries and resets to ready', () async {
    final reconnectReady = Completer<void>();
    final transport = FakeSttSessionTransport()
      ..connectResults.addAll([Future<void>.value(), reconnectReady.future]);
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
    );
    await controller.start();
    transport.eventController.add(
      const SttSessionClosedEvent(unexpected: true),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, LiveSessionState.reconnecting);

    await controller.stop();
    reconnectReady.complete();
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, LiveSessionState.ready);
    expect(controller.elapsed, Duration.zero);
    controller.dispose();
    await transport.eventController.close();
  });

  test('stop from error clears error and resets to ready', () async {
    final permissionGateway = FakeMicrophonePermissionGateway()
      ..result = MicrophonePermissionResult.denied;
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: permissionGateway,
      transport: transport,
    );
    await controller.start();
    expect(controller.state, LiveSessionState.error);

    await controller.stop();

    expect(controller.state, LiveSessionState.ready);
    expect(controller.errorMessage, isNull);
    expect(controller.elapsed, Duration.zero);
    controller.dispose();
    await transport.eventController.close();
  });

  test('retry restarts a recoverable connection failure', () async {
    final permissionGateway = FakeMicrophonePermissionGateway();
    final clock = FakeSessionClock();
    final ticker = FakeSessionTicker(clock);
    final transport = FakeSttSessionTransport()
      ..connectError = Exception('connection refused');
    final controller = LiveSessionController(
      permissionGateway: permissionGateway,
      transport: transport,
      clock: clock,
      ticker: ticker,
    );
    await controller.start();
    expect(controller.state, LiveSessionState.error);
    expect(controller.canRetry, isTrue);
    transport.connectError = null;
    final retryStates = <LiveSessionState>[];
    controller.addListener(() => retryStates.add(controller.state));

    await controller.retry();

    expect(retryStates, <LiveSessionState>[
      LiveSessionState.ready,
      LiveSessionState.permission,
      LiveSessionState.connecting,
      LiveSessionState.listening,
    ]);
    expect(controller.state, LiveSessionState.listening);
    expect(controller.errorMessage, isNull);
    expect(controller.elapsed, Duration.zero);
    expect(permissionGateway.requestCalls, 2);
    expect(transport.connectCalls, 2);
    controller.dispose();
    await transport.eventController.close();
  });

  test('double fresh retry begins only one new session flow', () async {
    final permissionGateway = FakeMicrophonePermissionGateway();
    final transport = FakeSttSessionTransport()
      ..connectError = Exception('connection refused');
    final controller = LiveSessionController(
      permissionGateway: permissionGateway,
      transport: transport,
    );
    await controller.start();
    expect(controller.state, LiveSessionState.error);
    transport.connectError = null;
    transport.pendingDisconnect = Completer<void>();

    final firstRetry = controller.retry();
    await Future<void>.delayed(Duration.zero);
    final secondRetry = controller.retry();
    await Future<void>.delayed(Duration.zero);

    expect(transport.disconnectCalls, 1);
    expect(permissionGateway.requestCalls, 1);

    transport.pendingDisconnect!.complete();
    await Future.wait([firstRetry, secondRetry]);
    expect(controller.state, LiveSessionState.listening);
    expect(permissionGateway.requestCalls, 2);
    expect(transport.connectCalls, 2);

    controller.dispose();
    await transport.eventController.close();
  });

  test('stop cancels a fresh retry waiting for cleanup', () async {
    final permissionGateway = FakeMicrophonePermissionGateway();
    final transport = FakeSttSessionTransport()
      ..connectError = Exception('connection refused');
    final controller = LiveSessionController(
      permissionGateway: permissionGateway,
      transport: transport,
    );
    await controller.start();
    expect(controller.state, LiveSessionState.error);
    expect(controller.elapsed, Duration.zero);
    transport.connectError = null;
    transport.pendingDisconnect = Completer<void>();

    final retryFuture = controller.retry();
    await Future<void>.delayed(Duration.zero);
    final stopFuture = controller.stop();
    await Future<void>.delayed(Duration.zero);

    transport.pendingDisconnect!.complete();
    await Future.wait([retryFuture, stopFuture]);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, LiveSessionState.ready);
    expect(controller.elapsed, Duration.zero);
    expect(permissionGateway.requestCalls, 1);
    expect(transport.connectCalls, 1);
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, LiveSessionState.ready);

    controller.dispose();
    await transport.eventController.close();
  });

  test('stop clears transcript from the completed session', () async {
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
    );
    await controller.start();
    transport.eventController.add(
      const SttTranscriptEvent(
        kind: SttTranscriptKind.finalResult,
        segmentId: 'segment-1',
        text: 'Previous session',
        language: 'vi',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.transcript, 'Previous session');

    await controller.stop();

    expect(controller.transcript, isEmpty);
    controller.dispose();
    await transport.eventController.close();
  });

  test('dispose requests transport cleanup', () async {
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
    );
    await controller.start();

    controller.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(transport.disconnectCalls, 1);
    await transport.eventController.close();
  });

  test('permission request failure becomes an actionable error', () async {
    final permissionGateway = FakeMicrophonePermissionGateway()
      ..requestError = Exception('platform channel unavailable');
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: permissionGateway,
      transport: transport,
    );

    await controller.start();

    expect(controller.state, LiveSessionState.error);
    expect(controller.errorMessage, 'Unable to request microphone permission.');
    expect(controller.canRetry, isTrue);
    controller.dispose();
    await transport.eventController.close();
  });

  test('permission state keeps elapsed time at zero', () async {
    final clock = FakeSessionClock();
    final ticker = FakeSessionTicker(clock);
    final permissionReady = Completer<MicrophonePermissionResult>();
    final permissionGateway = FakeMicrophonePermissionGateway()
      ..pendingRequest = permissionReady;
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: permissionGateway,
      transport: transport,
      clock: clock,
      ticker: ticker,
    );

    unawaited(controller.start());
    ticker.advance(const Duration(seconds: 5));

    expect(controller.state, LiveSessionState.permission);
    expect(controller.elapsed, Duration.zero);
    await controller.stop();
    permissionReady.complete(MicrophonePermissionResult.granted);
    controller.dispose();
    await transport.eventController.close();
  });

  test('connecting state keeps elapsed time at zero', () async {
    final clock = FakeSessionClock();
    final ticker = FakeSessionTicker(clock);
    final connectReady = Completer<void>();
    final transport = FakeSttSessionTransport()..pendingConnect = connectReady;
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      clock: clock,
      ticker: ticker,
    );

    unawaited(controller.start());
    await Future<void>.delayed(Duration.zero);
    ticker.advance(const Duration(seconds: 5));

    expect(controller.state, LiveSessionState.connecting);
    expect(controller.elapsed, Duration.zero);
    await controller.stop();
    connectReady.complete();
    controller.dispose();
    await transport.eventController.close();
  });
}

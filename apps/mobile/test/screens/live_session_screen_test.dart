import 'dart:async';
import 'dart:typed_data';

import 'package:ai_live_translator_mobile/app.dart';
import 'package:ai_live_translator_mobile/screens/live_session_screen.dart';
import 'package:ai_live_translator_mobile/services/debug_stt_session_transport.dart';
import 'package:ai_live_translator_mobile/services/microphone_capture_service.dart';
import 'package:ai_live_translator_mobile/services/microphone_permission_service.dart';
import 'package:ai_live_translator_mobile/services/stt_websocket_service.dart';
import 'package:ai_live_translator_mobile/session/live_session_controller.dart';
import 'package:ai_live_translator_mobile/session/session_timer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeScreenPermissionGateway implements MicrophonePermissionGateway {
  MicrophonePermissionResult result = MicrophonePermissionResult.granted;
  Completer<MicrophonePermissionResult>? pendingRequest;

  @override
  Future<MicrophonePermissionResult> requestPermission() async {
    return pendingRequest?.future ?? result;
  }

  @override
  Future<bool> openAppSettings() async => true;
}

class FakeScreenTransport implements SttSessionTransport {
  final StreamController<SttSessionEvent> eventController =
      StreamController<SttSessionEvent>.broadcast();
  Completer<void>? pendingConnect;
  Object? connectError;

  @override
  Stream<SttSessionEvent> get events => eventController.stream;

  @override
  Future<void> connect() async {
    await pendingConnect?.future;
    if (connectError != null) {
      throw connectError!;
    }
  }

  @override
  Future<void> sendAudio(Uint8List audio) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> stop() async {}
}

class FakeScreenClock implements SessionClock {
  Duration value = Duration.zero;

  @override
  Duration get now => value;
}

class FakeScreenTicker implements SessionTicker {
  FakeScreenTicker(this.clock);

  final FakeScreenClock clock;
  VoidCallback? callback;

  @override
  void start(VoidCallback onTick) {
    callback = onTick;
  }

  @override
  void stop() {
    callback = null;
  }

  @override
  void dispose() {
    callback = null;
  }

  void advance(Duration duration) {
    clock.value += duration;
    callback?.call();
  }
}

class FakeDebugControls implements DebugSttSessionControls {
  int completeCalls = 0;
  int holdCalls = 0;
  int failCalls = 0;
  int disconnectCalls = 0;

  @override
  bool hasPendingReconnect = false;

  @override
  void completeReconnectSuccessfully() {
    completeCalls++;
  }

  @override
  void configureNextReconnectToWait() {
    holdCalls++;
  }

  @override
  void configureReconnectsToFail() {
    failCalls++;
  }

  @override
  Future<void> simulateUnexpectedDisconnect() async {
    disconnectCalls++;
  }
}

void main() {
  testWidgets('app passes injected debug controls to live session screen', (
    tester,
  ) async {
    final transport = FakeScreenTransport();

    await tester.pumpWidget(
      AiLiveTranslatorApp(
        permissionGateway: FakeScreenPermissionGateway(),
        sessionTransport: transport,
        microphoneCapture: DebugNoopMicrophoneCapture(),
        debugControls: FakeDebugControls(),
      ),
    );

    expect(find.text('DEBUG VERIFICATION MODE'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await transport.eventController.close();
  });

  testWidgets('debug verification controls are hidden without debug seam', (
    tester,
  ) async {
    final transport = FakeScreenTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
    );

    await tester.pumpWidget(
      MaterialApp(home: LiveSessionScreen(controller: controller)),
    );

    expect(find.text('DEBUG VERIFICATION MODE'), findsNothing);
    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('debug verification controls appear when seam is injected', (
    tester,
  ) async {
    final transport = FakeScreenTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LiveSessionScreen(
          controller: controller,
          debugControls: FakeDebugControls(),
        ),
      ),
    );

    expect(find.text('DEBUG VERIFICATION MODE'), findsOneWidget);
    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('debug Simulate Disconnect holds the next reconnect', (
    tester,
  ) async {
    final transport = FakeScreenTransport();
    final controls = FakeDebugControls();
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
    );
    await controller.start();
    await tester.pumpWidget(
      MaterialApp(
        home: LiveSessionScreen(
          controller: controller,
          debugControls: controls,
        ),
      ),
    );

    await tester.tap(find.text('Simulate Disconnect'));

    expect(controls.holdCalls, 1);
    expect(controls.disconnectCalls, 1);
    await tester.runAsync(controller.stop);
    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('debug Fail Reconnects configures failures and disconnects', (
    tester,
  ) async {
    final transport = FakeScreenTransport();
    final controls = FakeDebugControls();
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
    );
    await controller.start();
    await tester.pumpWidget(
      MaterialApp(
        home: LiveSessionScreen(
          controller: controller,
          debugControls: controls,
        ),
      ),
    );

    await tester.tap(find.text('Fail Reconnects'));

    expect(controls.failCalls, 1);
    expect(controls.disconnectCalls, 1);
    await tester.runAsync(controller.stop);
    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('held reconnect exposes debug completion control', (
    tester,
  ) async {
    final reconnectReady = Completer<void>();
    final transport = FakeScreenTransport();
    final controls = FakeDebugControls()..hasPendingReconnect = true;
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
    );
    await controller.start();
    transport.pendingConnect = reconnectReady;
    await tester.pumpWidget(
      MaterialApp(
        home: LiveSessionScreen(
          controller: controller,
          debugControls: controls,
        ),
      ),
    );
    transport.eventController.add(
      const SttSessionClosedEvent(unexpected: true),
    );
    await tester.pump();

    await tester.tap(find.text('Complete Reconnect'));

    expect(controls.completeCalls, 1);
    await tester.runAsync(controller.stop);
    reconnectReady.complete();
    await tester.pump();
    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('actual debug controls hold and complete reconnect', (
    tester,
  ) async {
    final transport = DebugSttSessionTransport(
      initialConnectDelay: Duration.zero,
    );
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
    );
    await tester.runAsync(controller.start);
    await tester.pumpWidget(
      MaterialApp(
        home: LiveSessionScreen(
          controller: controller,
          debugControls: transport,
        ),
      ),
    );

    await tester.tap(find.text('Simulate Disconnect'));
    await tester.pump();

    expect(find.text('Reconnecting'), findsOneWidget);
    expect(find.text('Complete Reconnect'), findsOneWidget);

    await tester.tap(find.text('Complete Reconnect'));
    await tester.pump();

    expect(find.text('Listening'), findsOneWidget);
    await tester.runAsync(controller.stop);
    controller.dispose();
    await tester.pump();
    await transport.dispose();
  });

  testWidgets('ready shows Start and not Stop', (tester) async {
    final transport = FakeScreenTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
    );

    await tester.pumpWidget(
      MaterialApp(home: LiveSessionScreen(controller: controller)),
    );

    expect(find.text('Live Session'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Start'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);

    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('connecting displays Connecting with progress', (tester) async {
    final connectReady = Completer<void>();
    final transport = FakeScreenTransport()..pendingConnect = connectReady;
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
    );
    await tester.pumpWidget(
      MaterialApp(home: LiveSessionScreen(controller: controller)),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    await tester.pump();

    expect(find.text('Connecting'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Stop'), findsOneWidget);

    await tester.runAsync(controller.stop);
    connectReady.complete();
    await tester.pump();
    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('permission request displays microphone permission status', (
    tester,
  ) async {
    final permissionReady = Completer<MicrophonePermissionResult>();
    final permissionGateway = FakeScreenPermissionGateway()
      ..pendingRequest = permissionReady;
    final transport = FakeScreenTransport();
    final controller = LiveSessionController(
      permissionGateway: permissionGateway,
      transport: transport,
    );
    await tester.pumpWidget(
      MaterialApp(home: LiveSessionScreen(controller: controller)),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    await tester.pump();

    expect(find.text('Requesting microphone permission'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);

    await tester.runAsync(controller.stop);
    permissionReady.complete(MicrophonePermissionResult.granted);
    await tester.pump();
    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('listening shows Pause and Stop', (tester) async {
    final transport = FakeScreenTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
    );
    await controller.start();

    await tester.pumpWidget(
      MaterialApp(home: LiveSessionScreen(controller: controller)),
    );

    expect(find.text('Listening'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Pause'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Stop'), findsOneWidget);

    await tester.runAsync(controller.stop);
    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('paused shows Resume and Stop', (tester) async {
    final transport = FakeScreenTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
    );
    await controller.start();
    controller.pause();

    await tester.pumpWidget(
      MaterialApp(home: LiveSessionScreen(controller: controller)),
    );

    expect(find.text('Paused'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Resume'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Stop'), findsOneWidget);

    await tester.runAsync(controller.stop);
    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('reconnecting displays status with progress and Stop', (
    tester,
  ) async {
    final reconnectReady = Completer<void>();
    final transport = FakeScreenTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
    );
    await controller.start();
    transport.pendingConnect = reconnectReady;
    await tester.pumpWidget(
      MaterialApp(home: LiveSessionScreen(controller: controller)),
    );

    transport.eventController.add(
      const SttSessionClosedEvent(unexpected: true),
    );
    await tester.pump();

    expect(find.text('Reconnecting'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Stop'), findsOneWidget);

    await tester.runAsync(controller.stop);
    reconnectReady.complete();
    await tester.pump();
    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('error displays normalized message and valid actions', (
    tester,
  ) async {
    final transport = FakeScreenTransport()
      ..connectError = const SttSessionException(
        code: 'provider_unavailable',
        message: 'STT provider is unavailable.',
        recoverable: false,
      );
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
    );
    await controller.start();

    await tester.pumpWidget(
      MaterialApp(home: LiveSessionScreen(controller: controller)),
    );

    expect(find.text('Error'), findsOneWidget);
    expect(find.text('STT provider is unavailable.'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Stop'), findsOneWidget);

    await tester.runAsync(controller.stop);
    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('Stop returns visible UI to Ready', (tester) async {
    final transport = FakeScreenTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
    );
    await controller.start();
    await tester.pumpWidget(
      MaterialApp(home: LiveSessionScreen(controller: controller)),
    );

    final stopButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Stop'),
    );
    await tester.runAsync(() async {
      stopButton.onPressed!();
      await controller.stop();
    });
    await tester.pump();

    expect(find.text('Ready'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Start'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);
    expect(find.text('00:00'), findsOneWidget);
    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('timer text reflects deterministic controller time', (
    tester,
  ) async {
    final clock = FakeScreenClock();
    final ticker = FakeScreenTicker(clock);
    final transport = FakeScreenTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
      clock: clock,
      ticker: ticker,
    );
    await controller.start();
    await tester.pumpWidget(
      MaterialApp(home: LiveSessionScreen(controller: controller)),
    );

    ticker.advance(const Duration(seconds: 65));
    await tester.pump();

    expect(find.text('01:05'), findsOneWidget);
    controller.pause();
    ticker.advance(const Duration(seconds: 10));
    await tester.pump();
    expect(find.text('01:05'), findsOneWidget);

    await tester.runAsync(controller.stop);
    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('renders transcript received from normalized transport event', (
    tester,
  ) async {
    final transport = FakeScreenTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
    );
    await controller.start();
    await tester.pumpWidget(
      MaterialApp(home: LiveSessionScreen(controller: controller)),
    );

    transport.eventController.add(
      const SttTranscriptEvent(
        kind: SttTranscriptKind.finalResult,
        segmentId: 'segment-1',
        text: 'Actual backend transcript',
        language: 'vi',
      ),
    );
    await tester.pump();

    expect(find.text('Transcript'), findsOneWidget);
    expect(find.text('Actual backend transcript'), findsOneWidget);

    await tester.runAsync(controller.stop);
    controller.dispose();
    await transport.eventController.close();
  });
}

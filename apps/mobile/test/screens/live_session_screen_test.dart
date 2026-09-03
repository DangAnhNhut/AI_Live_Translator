import 'dart:async';
import 'dart:typed_data';

import 'package:ai_live_translator_mobile/app.dart';
import 'package:ai_live_translator_mobile/screens/live_session_screen.dart';
import 'package:ai_live_translator_mobile/services/audio_input.dart';
import 'package:ai_live_translator_mobile/services/debug_stt_session_transport.dart';
import 'package:ai_live_translator_mobile/services/microphone_capture_service.dart';
import 'package:ai_live_translator_mobile/services/microphone_permission_service.dart';
import 'package:ai_live_translator_mobile/services/stt_websocket_service.dart';
import 'package:ai_live_translator_mobile/services/transcript_file_saver.dart';
import 'package:ai_live_translator_mobile/session/live_session_controller.dart';
import 'package:ai_live_translator_mobile/session/session_timer.dart';
import 'package:ai_live_translator_mobile/translation/translation_domain.dart';
import 'package:ai_live_translator_mobile/widgets/bilingual_transcript_block.dart';
import 'package:ai_live_translator_mobile/widgets/translation_language_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeScreenPermissionGateway implements MicrophonePermissionGateway {
  MicrophonePermissionResult result = MicrophonePermissionResult.granted;
  Completer<MicrophonePermissionResult>? pendingRequest;
  int requestCalls = 0;

  @override
  Future<MicrophonePermissionResult> requestPermission() async {
    requestCalls++;
    return pendingRequest?.future ?? result;
  }

  @override
  Future<bool> openAppSettings() async => true;
}

class FakeScreenAudioInput implements MobileAudioInput {
  final StreamController<Uint8List> audioController =
      StreamController<Uint8List>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<Stream<Uint8List>> start() async {
    startCalls++;
    return audioController.stream;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {}
}

class FakeScreenTransport implements SttSessionTransport {
  final StreamController<SttSessionEvent> eventController =
      StreamController<SttSessionEvent>.broadcast();
  Completer<void>? pendingConnect;
  Object? connectError;

  @override
  Stream<SttSessionEvent> get events => eventController.stream;

  @override
  Future<void> connect({
    SttSessionStartOptions options = const SttSessionStartOptions(),
  }) async {
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

class FakeTranscriptFileSaver implements TranscriptFileSaver {
  FakeTranscriptFileSaver({this.outcome = TranscriptSaveOutcome.success});

  TranscriptSaveOutcome outcome;
  final List<String> savedTranscripts = [];

  @override
  Future<TranscriptSaveOutcome> save(String transcript) async {
    savedTranscripts.add(transcript);
    return outcome;
  }
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

void main() {
  testWidgets('app wires System Audio availability into the live controller', (
    tester,
  ) async {
    final transport = FakeScreenTransport();
    final systemAudio = FakeScreenAudioInput();

    await tester.pumpWidget(
      AiLiveTranslatorApp(
        permissionGateway: FakeScreenPermissionGateway(),
        sessionTransport: transport,
        microphoneCapture: DebugNoopMicrophoneCapture(),
        systemAudioInput: systemAudio,
        systemAudioSupportQuery: () async => true,
      ),
    );
    await tester.pump();

    expect(
      find.text('Capture playback audio from supported apps.'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await transport.eventController.close();
    await systemAudio.audioController.close();
  });

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

    await tapVisible(tester, find.text('Simulate Disconnect'));

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

    await tapVisible(tester, find.text('Fail Reconnects'));

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

    await tapVisible(tester, find.text('Complete Reconnect'));

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

    await tapVisible(tester, find.text('Simulate Disconnect'));
    await tester.pump();

    expect(find.text('Reconnecting'), findsOneWidget);
    expect(find.text('Complete Reconnect'), findsOneWidget);

    await tapVisible(tester, find.text('Complete Reconnect'));
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
    expect(find.text('Save Transcript'), findsNothing);

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

    await tapVisible(tester, find.widgetWithText(FilledButton, 'Start'));
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

    await tapVisible(tester, find.widgetWithText(FilledButton, 'Start'));
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

  testWidgets('stopped interim-only session shows disabled Save Transcript', (
    tester,
  ) async {
    final transport = FakeScreenTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
    );
    await controller.start();
    transport.eventController.add(
      const SttTranscriptEvent(
        kind: SttTranscriptKind.interim,
        segmentId: 'segment-1',
        text: 'xin chào hôm',
        language: 'vi',
      ),
    );
    await tester.pump();
    await tester.runAsync(controller.stop);

    await tester.pumpWidget(
      MaterialApp(home: LiveSessionScreen(controller: controller)),
    );

    final saveButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Save Transcript'),
    );
    expect(saveButton.onPressed, isNull);
    expect(find.text('xin chào hôm'), findsNothing);
    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('Save Transcript sends only final text and shows success', (
    tester,
  ) async {
    final transport = FakeScreenTransport();
    final saver = FakeTranscriptFileSaver();
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
    );
    await controller.start();
    transport.eventController.add(
      const SttTranscriptEvent(
        kind: SttTranscriptKind.finalResult,
        segmentId: 'segment-1',
        text: 'Xin chào hôm nay.',
        language: 'vi',
      ),
    );
    transport.eventController.add(
      const SttTranscriptEvent(
        kind: SttTranscriptKind.interim,
        segmentId: 'segment-2',
        text: 'không được lưu',
        language: 'vi',
      ),
    );
    await tester.pump();
    await tester.runAsync(controller.stop);
    await tester.pumpWidget(
      MaterialApp(
        home: LiveSessionScreen(controller: controller, transcriptSaver: saver),
      ),
    );

    await tapVisible(tester, find.text('Save Transcript'));
    await tester.pump();

    expect(saver.savedTranscripts, ['Xin chào hôm nay.']);
    expect(find.text('Transcript saved successfully'), findsOneWidget);
    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('cancelled transcript save shows no message', (tester) async {
    final transport = FakeScreenTransport();
    final saver = FakeTranscriptFileSaver(
      outcome: TranscriptSaveOutcome.cancelled,
    );
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
    );
    await controller.start();
    transport.eventController.add(
      const SttTranscriptEvent(
        kind: SttTranscriptKind.finalResult,
        segmentId: 'segment-1',
        text: 'Final transcript.',
        language: 'vi',
      ),
    );
    await tester.pump();
    await tester.runAsync(controller.stop);
    await tester.pumpWidget(
      MaterialApp(
        home: LiveSessionScreen(controller: controller, transcriptSaver: saver),
      ),
    );

    await tapVisible(tester, find.text('Save Transcript'));
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('failed transcript save shows an understandable message', (
    tester,
  ) async {
    final transport = FakeScreenTransport();
    final saver = FakeTranscriptFileSaver(
      outcome: TranscriptSaveOutcome.failed,
    );
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
    );
    await controller.start();
    transport.eventController.add(
      const SttTranscriptEvent(
        kind: SttTranscriptKind.finalResult,
        segmentId: 'segment-1',
        text: 'Final transcript.',
        language: 'vi',
      ),
    );
    await tester.pump();
    await tester.runAsync(controller.stop);
    await tester.pumpWidget(
      MaterialApp(
        home: LiveSessionScreen(controller: controller, transcriptSaver: saver),
      ),
    );

    await tapVisible(tester, find.text('Save Transcript'));
    await tester.pump();

    expect(find.text('Unable to save transcript'), findsOneWidget);
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

  testWidgets('ready screen shows both sources with microphone selected', (
    tester,
  ) async {
    final transport = FakeScreenTransport();
    final systemAudio = FakeScreenAudioInput();
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
      systemAudioInput: systemAudio,
      systemAudioSupportQuery: () async => true,
    );
    await controller.audioSourceSupportReady;

    await tester.pumpWidget(
      MaterialApp(home: LiveSessionScreen(controller: controller)),
    );

    expect(find.text('Audio Source'), findsOneWidget);
    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('System Audio'), findsOneWidget);
    final microphone = tester.widget<Semantics>(
      find.byKey(const Key('audio_source_microphone')),
    );
    expect(microphone.properties.selected, isTrue);

    controller.dispose();
    await transport.eventController.close();
    await systemAudio.audioController.close();
  });

  testWidgets('selecting system audio requests no permission until Start', (
    tester,
  ) async {
    final permission = FakeScreenPermissionGateway();
    final transport = FakeScreenTransport();
    final systemAudio = FakeScreenAudioInput();
    final controller = LiveSessionController(
      permissionGateway: permission,
      transport: transport,
      systemAudioInput: systemAudio,
      systemAudioSupportQuery: () async => true,
    );
    await controller.audioSourceSupportReady;
    await tester.pumpWidget(
      MaterialApp(home: LiveSessionScreen(controller: controller)),
    );

    await tester.tap(find.byKey(const Key('audio_source_system_audio')));
    await tester.pump();

    expect(controller.selectedAudioSource, MobileAudioSource.systemAudio);
    expect(permission.requestCalls, 0);
    expect(systemAudio.startCalls, 0);

    controller.dispose();
    await transport.eventController.close();
    await systemAudio.audioController.close();
  });

  testWidgets('unsupported system audio is visibly unavailable', (
    tester,
  ) async {
    final transport = FakeScreenTransport();
    final systemAudio = FakeScreenAudioInput();
    final controller = LiveSessionController(
      permissionGateway: FakeScreenPermissionGateway(),
      transport: transport,
      systemAudioInput: systemAudio,
      systemAudioSupportQuery: () async => false,
    );
    await controller.audioSourceSupportReady;
    await tester.pumpWidget(
      MaterialApp(home: LiveSessionScreen(controller: controller)),
    );

    final option = tester.widget<Semantics>(
      find.byKey(const Key('audio_source_system_audio')),
    );
    expect(option.properties.enabled, isFalse);
    expect(find.text('Requires Android 10 or later'), findsOneWidget);

    await tester.tap(find.byKey(const Key('audio_source_system_audio')));
    expect(controller.selectedAudioSource, MobileAudioSource.microphone);

    controller.dispose();
    await transport.eventController.close();
    await systemAudio.audioController.close();
  });

  testWidgets(
    'active session locks source selection and retains it after Stop',
    (tester) async {
      final transport = FakeScreenTransport();
      final systemAudio = FakeScreenAudioInput();
      final controller = LiveSessionController(
        permissionGateway: FakeScreenPermissionGateway(),
        transport: transport,
        systemAudioInput: systemAudio,
        systemAudioSupportQuery: () async => true,
      );
      await controller.audioSourceSupportReady;
      controller.selectAudioSource(MobileAudioSource.systemAudio);
      await controller.start();
      await tester.pumpWidget(
        MaterialApp(home: LiveSessionScreen(controller: controller)),
      );

      final microphone = tester.widget<Semantics>(
        find.byKey(const Key('audio_source_microphone')),
      );
      expect(microphone.properties.enabled, isFalse);
      await tester.tap(find.byKey(const Key('audio_source_microphone')));
      expect(controller.selectedAudioSource, MobileAudioSource.systemAudio);

      await tester.runAsync(controller.stop);
      await tester.pump();

      expect(controller.selectedAudioSource, MobileAudioSource.systemAudio);
      final systemOption = tester.widget<Semantics>(
        find.byKey(const Key('audio_source_system_audio')),
      );
      expect(systemOption.properties.enabled, isTrue);

      controller.dispose();
      await transport.eventController.close();
      await systemAudio.audioController.close();
    },
  );

  testWidgets('Live screen exposes and locks the Translation target', (
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

    expect(find.byType(TranslationLanguageSelector), findsOneWidget);
    expect(find.text('Vietnamese'), findsOneWidget);
    expect(find.text('English · en'), findsOneWidget);
    var selector = tester.widget<TranslationLanguageSelector>(
      find.byType(TranslationLanguageSelector),
    );
    expect(selector.enabled, isTrue);

    await tester.runAsync(controller.start);
    await tester.pump();
    selector = tester.widget<TranslationLanguageSelector>(
      find.byType(TranslationLanguageSelector),
    );
    expect(selector.enabled, isFalse);

    await tester.runAsync(controller.stop);
    await tester.pump();
    selector = tester.widget<TranslationLanguageSelector>(
      find.byType(TranslationLanguageSelector),
    );
    expect(selector.enabled, isTrue);

    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('Live Speech becomes one bilingual block and updates in place', (
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
        streamId: 'stream_A',
        segmentId: 'seg_1',
        text: 'Raw final.',
        language: 'vi',
      ),
    );
    transport.eventController.add(
      const SttTranscriptEvent(
        kind: SttTranscriptKind.interim,
        streamId: 'stream_A',
        segmentId: 'seg_live',
        text: 'Speaking now',
        language: 'vi',
      ),
    );
    await tester.pump();

    expect(find.text('Live Speech'), findsOneWidget);
    expect(find.text('Raw final.'), findsOneWidget);
    expect(find.text('Speaking now'), findsOneWidget);

    transport.eventController.add(
      const SttTranslationEvent(
        TranslationPendingEvent(
          streamId: 'stream_A',
          utteranceId: 'utt_000001',
          sourceSegmentIds: ['seg_1'],
          sourceText: 'Canonical source.',
          sourceLanguage: 'vi',
          targetLanguage: TranslationTargetLanguage.english,
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(BilingualTranscriptBlock), findsOneWidget);
    expect(find.text('Canonical source.'), findsOneWidget);
    expect(find.text('Translating...'), findsOneWidget);
    expect(find.text('Raw final.'), findsNothing);
    expect(find.text('Speaking now'), findsOneWidget);

    transport.eventController.add(
      const SttTranslationEvent(
        TranslationFinalEvent(
          streamId: 'stream_A',
          utteranceId: 'utt_000001',
          sourceSegmentIds: ['seg_1'],
          sourceText: 'Canonical source.',
          sourceLanguage: 'vi',
          targetLanguage: TranslationTargetLanguage.english,
          translatedText: 'Canonical translation.',
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(BilingualTranscriptBlock), findsOneWidget);
    expect(find.text('Canonical translation.'), findsOneWidget);
    expect(find.text('Translating...'), findsNothing);

    await tester.runAsync(controller.stop);
    controller.dispose();
    await transport.eventController.close();
  });

  testWidgets('Translation failures stay inline and source remains usable', (
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
      const SttTranslationEvent(
        TranslationUtteranceErrorEvent(
          streamId: 'stream_A',
          utteranceId: 'utt_000001',
          sourceSegmentIds: ['seg_1'],
          sourceText: 'Original survives.',
          sourceLanguage: 'vi',
          targetLanguage: TranslationTargetLanguage.english,
          code: 'queue_overflow',
          message: 'Busy.',
        ),
      ),
    );
    transport.eventController.add(
      const SttTranslationEvent(
        TranslationSessionErrorEvent(
          streamId: 'stream_A',
          sourceLanguage: 'vi',
          targetLanguage: TranslationTargetLanguage.english,
          code: 'provider_unavailable',
          message: 'Unavailable.',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Original survives.'), findsOneWidget);
    expect(find.text('Translation unavailable'), findsOneWidget);
    expect(
      find.text(
        'Translation is unavailable. Original transcript will continue.',
      ),
      findsOneWidget,
    );
    expect(find.text('Listening'), findsOneWidget);
    expect(find.byKey(const Key('session_error')), findsNothing);

    await tester.runAsync(controller.stop);
    controller.dispose();
    await transport.eventController.close();
  });
}

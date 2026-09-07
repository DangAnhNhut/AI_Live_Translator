import 'dart:async';
import 'dart:typed_data';

import 'package:ai_live_translator_mobile/app.dart';
import 'package:ai_live_translator_mobile/screens/home_screen.dart';
import 'package:ai_live_translator_mobile/screens/live_session_screen.dart';
import 'package:ai_live_translator_mobile/services/microphone_capture_service.dart';
import 'package:ai_live_translator_mobile/services/microphone_permission_service.dart';
import 'package:ai_live_translator_mobile/services/stt_websocket_service.dart';
import 'package:ai_live_translator_mobile/session/live_session_controller.dart';
import 'package:ai_live_translator_mobile/session/live_session_state.dart';
import 'package:ai_live_translator_mobile/session/session_timer.dart';
import 'package:ai_live_translator_mobile/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePermissionGateway implements MicrophonePermissionGateway {
  MicrophonePermissionResult result = MicrophonePermissionResult.granted;
  int requestCalls = 0;

  @override
  Future<MicrophonePermissionResult> requestPermission() async {
    requestCalls++;
    return result;
  }

  @override
  Future<bool> openAppSettings() async => true;
}

class _FakeTransport implements SttSessionTransport {
  final StreamController<SttSessionEvent> eventController =
      StreamController<SttSessionEvent>.broadcast();
  int connectCalls = 0;
  int stopCalls = 0;
  int disconnectCalls = 0;

  @override
  Stream<SttSessionEvent> get events => eventController.stream;

  @override
  Future<void> connect({
    SttSessionStartOptions options = const SttSessionStartOptions(),
  }) async {
    connectCalls++;
  }

  @override
  Future<void> sendAudio(Uint8List audio) async {}

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

class _FakeMicrophoneCapture implements MobileMicrophoneCapture {
  final StreamController<Uint8List> audioController =
      StreamController<Uint8List>.broadcast();
  int startCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int stopCalls = 0;

  @override
  Future<Stream<Uint8List>> start() async {
    startCalls++;
    return audioController.stream;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {}
}

class _FakeClock implements SessionClock {
  Duration value = Duration.zero;

  @override
  Duration get now => value;
}

class _FakeTicker implements SessionTicker {
  _FakeTicker(this.clock);

  final _FakeClock clock;
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
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

Widget _buildApp({
  required LiveSessionController controller,
}) {
  return MaterialApp(
    theme: buildAppTheme(),
    home: HomeScreen(controller: controller),
  );
}

void main() {
  late _FakePermissionGateway permissionGateway;
  late _FakeTransport transport;
  late _FakeMicrophoneCapture microphoneCapture;
  late _FakeClock clock;
  late _FakeTicker ticker;
  late LiveSessionController controller;

  setUp(() {
    permissionGateway = _FakePermissionGateway();
    transport = _FakeTransport();
    microphoneCapture = _FakeMicrophoneCapture();
    clock = _FakeClock();
    ticker = _FakeTicker(clock);
    controller = LiveSessionController(
      permissionGateway: permissionGateway,
      transport: transport,
      microphoneCapture: microphoneCapture,
      clock: clock,
      ticker: ticker,
    );
  });

  tearDown(() async {
    controller.dispose();
    await transport.eventController.close();
    await microphoneCapture.audioController.close();
  });

  testWidgets('1. App cold start renders HomeScreen', (tester) async {
    await tester.pumpWidget(
      AiLiveTranslatorApp(
        permissionGateway: permissionGateway,
        sessionTransport: transport,
        microphoneCapture: microphoneCapture,
      ),
    );

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('AI Live Translator'), findsOneWidget);
    expect(find.text('Realtime Speech & Translation'), findsOneWidget);
  });

  testWidgets('2. Home renders truthful brand and content', (tester) async {
    await tester.pumpWidget(_buildApp(controller: controller));

    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
    expect(find.text('AI Live Translator'), findsOneWidget);
    expect(find.text('Realtime Speech & Translation'), findsOneWidget);

    expect(find.text('LIVE TRANSLATION'), findsOneWidget);
    expect(find.text('Start live translation'), findsOneWidget);
    expect(
      find.text(
        'Translate speech in realtime and let others follow from any device.',
      ),
      findsOneWidget,
    );
    expect(find.text('Vietnamese'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_forward_rounded), findsOneWidget);
  });

  testWidgets('3. Home has one primary Start Live Translation CTA', (
    tester,
  ) async {
    await tester.pumpWidget(_buildApp(controller: controller));

    expect(
      find.byKey(const Key('home_start_translation_button')),
      findsOneWidget,
    );
    expect(find.text('Start Live Translation'), findsOneWidget);

    // No duplicate host/create actions
    expect(find.text('Host Session'), findsNothing);
    expect(find.text('Create Session'), findsNothing);
  });

  testWidgets('4. Unsupported Join Session features are absent', (
    tester,
  ) async {
    await tester.pumpWidget(_buildApp(controller: controller));

    expect(find.text('Join Session'), findsNothing);
    expect(find.text('Join by ID'), findsNothing);
    expect(find.text('Join by link'), findsNothing);
    expect(find.text('QR scan'), findsNothing);
    expect(find.text('Listener Mode'), findsNothing);
    expect(find.text('Viewer Mode'), findsNothing);
  });

  testWidgets('5. Fake Recent Sessions and bottom navigation are absent', (
    tester,
  ) async {
    await tester.pumpWidget(_buildApp(controller: controller));

    expect(find.text('Recent Sessions'), findsNothing);
    expect(find.text('History'), findsNothing);
    expect(find.text('Dictionary'), findsNothing);
    expect(find.text('Profile'), findsNothing);
    expect(find.text('Good evening,'), findsNothing);
    expect(find.text('Alex'), findsNothing);
    expect(find.byIcon(Icons.notifications), findsNothing);
    expect(find.byType(BottomNavigationBar), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('6. Start Live Translation pushes LiveSessionScreen', (
    tester,
  ) async {
    await tester.pumpWidget(_buildApp(controller: controller));

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(LiveSessionScreen), findsNothing);

    await tester.tap(find.byKey(const Key('home_start_translation_button')));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsNothing);
    expect(find.byType(LiveSessionScreen), findsOneWidget);
  });

  testWidgets('7. Pushed LiveSessionScreen starts in Ready state', (
    tester,
  ) async {
    await tester.pumpWidget(_buildApp(controller: controller));

    await tester.tap(find.byKey(const Key('home_start_translation_button')));
    await tester.pumpAndSettle();

    expect(find.text('Live Session'), findsOneWidget);
    expect(find.text('Ready to go live?'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Audio Source'), findsOneWidget);
    expect(find.text('Translation Target'), findsOneWidget);
  });

  testWidgets('8. Back from Ready returns to Home', (tester) async {
    await tester.pumpWidget(_buildApp(controller: controller));

    await tester.tap(find.byKey(const Key('home_start_translation_button')));
    await tester.pumpAndSettle();

    expect(find.byType(LiveSessionScreen), findsOneWidget);

    // Tap the AppBar back button
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.byType(LiveSessionScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Start Live Translation'), findsOneWidget);
  });

  testWidgets(
    '9. Back while active does NOT pop immediately and shows confirmation dialog',
    (tester) async {
      await tester.pumpWidget(_buildApp(controller: controller));

      await tester.tap(find.byKey(const Key('home_start_translation_button')));
      await tester.pumpAndSettle();

      // Start session
      await controller.start();
      await tester.pump();

      expect(controller.state, LiveSessionState.listening);

      // Attempt to pop via back button
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Confirmation dialog must appear
      expect(find.text('End live session?'), findsOneWidget);
      expect(find.text('End live session and return home?'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('End Session'), findsOneWidget);

      // LiveSessionScreen must NOT have popped
      expect(find.byType(LiveSessionScreen), findsOneWidget);
      expect(controller.state, LiveSessionState.listening);

      // Clean up session
      await tester.runAsync(controller.stop);
      await tester.pump();
    },
  );

  testWidgets(
    '10. Confirming exit while active uses clean stop lifecycle before pop',
    (tester) async {
      await tester.pumpWidget(_buildApp(controller: controller));

      await tester.tap(find.byKey(const Key('home_start_translation_button')));
      await tester.pumpAndSettle();

      await controller.start();
      await tester.pump();

      expect(controller.state, LiveSessionState.listening);

      // Trigger back navigation
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('End live session?'), findsOneWidget);

      // Confirm exit
      final endSessionButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'End Session'),
      );
      await tester.runAsync(() async {
        endSessionButton.onPressed!();
        await controller.stop();
      });
      await tester.pumpAndSettle();

      // Safe stop cleanup executed
      expect(transport.stopCalls, greaterThanOrEqualTo(1));
      expect(microphoneCapture.stopCalls, greaterThanOrEqualTo(1));

      // Successfully returned to Home
      expect(find.byType(LiveSessionScreen), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
    },
  );

  testWidgets('11. Canceling active-exit confirmation keeps session open', (
    tester,
  ) async {
    await tester.pumpWidget(_buildApp(controller: controller));

    await tester.tap(find.byKey(const Key('home_start_translation_button')));
    await tester.pumpAndSettle();

    await controller.start();
    await tester.pump();

    expect(controller.state, LiveSessionState.listening);

    // Trigger back navigation
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('End live session?'), findsOneWidget);

    // Cancel exit
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Dialog is dismissed, session remains active
    expect(find.text('End live session?'), findsNothing);
    expect(find.byType(LiveSessionScreen), findsOneWidget);
    expect(controller.state, LiveSessionState.listening);
    expect(transport.stopCalls, 0);

    // Clean up session
    await tester.runAsync(controller.stop);
    await tester.pump();
  });

  testWidgets(
    '12. Re-entering LiveSessionScreen does not show stale transcript/session state',
    (tester) async {
      await tester.pumpWidget(_buildApp(controller: controller));

      // First session entry
      await tester.tap(find.byKey(const Key('home_start_translation_button')));
      await tester.pumpAndSettle();

      await controller.start();
      await tester.pump();

      // Emit transcript event
      transport.eventController.add(
        const SttTranscriptEvent(
          kind: SttTranscriptKind.finalResult,
          segmentId: 'seg-1',
          text: 'Previous session words',
          language: 'vi',
        ),
      );
      await tester.pump();

      // Stop session via approved Stop button
      final stopButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Stop'),
      );
      await tester.runAsync(() async {
        stopButton.onPressed!();
        await controller.stop();
      });
      await tester.pumpAndSettle();

      // Now at Session Complete screen
      expect(find.text('Session complete'), findsOneWidget);
      expect(find.text('Previous session words'), findsOneWidget);

      // Return to Home
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);

      // Re-enter LiveSessionScreen
      await tester.tap(find.byKey(const Key('home_start_translation_button')));
      await tester.pumpAndSettle();

      // Must start in clean Ready state:
      // Session Complete and previous transcript must NOT leak
      expect(find.text('Session complete'), findsNothing);
      expect(find.text('Previous session words'), findsNothing);
      expect(find.text('Ready to go live?'), findsOneWidget);
      expect(find.text('Ready'), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);
    },
  );

  testWidgets('13. Back from Session Complete returns directly to Home', (
    tester,
  ) async {
    await tester.pumpWidget(_buildApp(controller: controller));

    await tester.tap(find.byKey(const Key('home_start_translation_button')));
    await tester.pumpAndSettle();

    await controller.start();
    await tester.pump();

    // Stop session
    final stopButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Stop'),
    );
    await tester.runAsync(() async {
      stopButton.onPressed!();
      await controller.stop();
    });
    await tester.pumpAndSettle();

    expect(find.text('Session complete'), findsOneWidget);

    // Back from Session Complete should pop cleanly without confirmation dialog
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('End live session?'), findsNothing);
    expect(find.byType(LiveSessionScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });
}

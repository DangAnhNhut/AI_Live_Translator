import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_live_translator_mobile/benchmark/stt_benchmark.dart';
import 'package:ai_live_translator_mobile/screens/live_session_screen.dart';
import 'package:ai_live_translator_mobile/services/microphone_permission_service.dart';
import 'package:ai_live_translator_mobile/services/stt_websocket_service.dart';
import 'package:ai_live_translator_mobile/session/live_session_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ScreenBenchmarkPermissionGateway implements MicrophonePermissionGateway {
  @override
  Future<bool> openAppSettings() async => false;

  @override
  Future<MicrophonePermissionResult> requestPermission() async =>
      MicrophonePermissionResult.granted;
}

class ScreenBenchmarkTransport implements SttSessionTransport {
  final eventController = StreamController<SttSessionEvent>.broadcast();

  @override
  Stream<SttSessionEvent> get events => eventController.stream;

  @override
  Future<void> connect({
    SttSessionStartOptions options = const SttSessionStartOptions(),
  }) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> sendAudio(Uint8List audio) async {}

  @override
  Future<void> stop() async {}
}

class StepBenchmarkClock implements BenchmarkElapsedClock {
  Duration value = Duration.zero;
  final Duration step;

  StepBenchmarkClock(this.step);

  @override
  Duration get elapsed {
    final result = value;
    value += step;
    return result;
  }
}

class ScreenBenchmarkSink implements BenchmarkJsonlSink {
  final lines = <String>[];

  @override
  void writeLine(String line) => lines.add(line);

  List<Map<String, Object?>> named(String eventName) => lines
      .map(
        (line) =>
            jsonDecode(line.substring(sttBenchmarkLinePrefix.length))
                as Map<String, Object?>,
      )
      .where((event) => event['event'] == eventName)
      .toList();
}

void main() {
  testWidgets(
    'transcript render records receive-to-post-frame timing without changing UI',
    (tester) async {
      final transport = ScreenBenchmarkTransport();
      final sink = ScreenBenchmarkSink();
      final recorder = SttBenchmarkRecorder(
        enabled: true,
        clock: StepBenchmarkClock(const Duration(milliseconds: 17)),
        sink: sink,
      );
      final controller = LiveSessionController(
        permissionGateway: ScreenBenchmarkPermissionGateway(),
        transport: transport,
        benchmark: recorder,
      );
      await controller.start();
      await tester.pumpWidget(
        MaterialApp(home: LiveSessionScreen(controller: controller)),
      );

      transport.eventController.add(
        const SttTranscriptEvent(
          kind: SttTranscriptKind.interim,
          segmentId: 'segment-1',
          text: 'Rendered transcript stays intact',
          language: 'en',
        ),
      );
      await tester.pump();

      expect(find.text('Rendered transcript stays intact'), findsOneWidget);
      final renderEvents = sink.named('mobile_receive_to_ui_render');
      expect(renderEvents, hasLength(1));
      expect(renderEvents.single['mobile_receive_to_ui_render_ms'], 17);

      await tester.runAsync(controller.stop);
      controller.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await transport.eventController.close();
    },
  );
}

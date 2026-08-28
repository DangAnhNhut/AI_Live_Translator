import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_live_translator_mobile/benchmark/stt_benchmark.dart';
import 'package:ai_live_translator_mobile/services/microphone_capture_service.dart';
import 'package:ai_live_translator_mobile/services/microphone_permission_service.dart';
import 'package:ai_live_translator_mobile/services/stt_websocket_service.dart';
import 'package:ai_live_translator_mobile/session/live_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class BenchmarkPermissionGateway implements MicrophonePermissionGateway {
  @override
  Future<bool> openAppSettings() async => false;

  @override
  Future<MicrophonePermissionResult> requestPermission() async =>
      MicrophonePermissionResult.granted;
}

class BenchmarkTransport implements SttSessionTransport {
  final eventsController = StreamController<SttSessionEvent>.broadcast();
  final sentAudio = <Uint8List>[];

  @override
  Stream<SttSessionEvent> get events => eventsController.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> sendAudio(Uint8List audio) async => sentAudio.add(audio);

  @override
  Future<void> stop() async {}
}

class BenchmarkMicrophone implements MobileMicrophoneCapture {
  final audioController = StreamController<Uint8List>.broadcast(sync: true);

  @override
  Future<void> dispose() async => audioController.close();

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<Stream<Uint8List>> start() async => audioController.stream;

  @override
  Future<void> stop() async {}
}

class ControllerBenchmarkClock implements BenchmarkElapsedClock {
  Duration value = Duration.zero;

  @override
  Duration get elapsed => value;
}

class ControllerBenchmarkSink implements BenchmarkJsonlSink {
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
  test(
    'controller forwards unchanged audio through enabled instrumentation',
    () async {
      final transport = BenchmarkTransport();
      final microphone = BenchmarkMicrophone();
      final sink = ControllerBenchmarkSink();
      final recorder = SttBenchmarkRecorder(
        enabled: true,
        clock: ControllerBenchmarkClock(),
        sink: sink,
        speechRmsThreshold: 1000,
        silenceRmsThreshold: 100,
        minimumSilenceDuration: Duration.zero,
        minimumSilenceChunks: 1,
      );
      final controller = LiveSessionController(
        permissionGateway: BenchmarkPermissionGateway(),
        transport: transport,
        microphoneCapture: microphone,
        benchmark: recorder,
      );
      await controller.start();
      final audio = Uint8List.fromList([0, 0, 208, 7]);
      final before = Uint8List.fromList(audio);

      microphone.audioController.add(audio);
      await Future<void>.delayed(Duration.zero);

      expect(transport.sentAudio.single, orderedEquals(before));
      expect(audio, orderedEquals(before));
      await controller.stop();
      controller.dispose();
      await transport.eventsController.close();
    },
  );

  test('default disabled controller preserves transcript behavior', () async {
    final transport = BenchmarkTransport();
    final controller = LiveSessionController(
      permissionGateway: BenchmarkPermissionGateway(),
      transport: transport,
    );

    transport.eventsController.add(
      const SttTranscriptEvent(
        kind: SttTranscriptKind.finalResult,
        segmentId: 'segment-1',
        text: 'Transcript remains unchanged',
        language: 'en',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.transcript, 'Transcript remains unchanged');
    expect(controller.benchmarkEnabled, isFalse);
    expect(controller.hasPendingBenchmarkTranscriptRender, isFalse);
    controller.dispose();
    await transport.eventsController.close();
  });
}

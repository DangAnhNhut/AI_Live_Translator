import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_live_translator_mobile/benchmark/stt_benchmark.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBenchmarkClock implements BenchmarkElapsedClock {
  Duration value = Duration.zero;

  @override
  Duration get elapsed => value;

  void advance(Duration duration) => value += duration;
}

class CapturingBenchmarkSink implements BenchmarkJsonlSink {
  final List<String> lines = [];

  @override
  void writeLine(String line) => lines.add(line);
}

class CountingRmsCalculator implements PcmRmsCalculator {
  int calls = 0;

  @override
  double calculateS16le(Uint8List pcm) {
    calls++;
    return 0;
  }
}

Uint8List pcmChunk(int sample, {int sampleCount = 160}) {
  final bytes = Uint8List(sampleCount * 2);
  final data = ByteData.sublistView(bytes);
  for (var index = 0; index < sampleCount; index++) {
    data.setInt16(index * 2, sample, Endian.little);
  }
  return bytes;
}

Map<String, Object?> decodeLine(String line) {
  expect(line, startsWith(sttBenchmarkLinePrefix));
  return jsonDecode(line.substring(sttBenchmarkLinePrefix.length))
      as Map<String, Object?>;
}

List<Map<String, Object?>> eventsNamed(
  CapturingBenchmarkSink sink,
  String name,
) => sink.lines
    .map(decodeLine)
    .where((event) => event['event'] == name)
    .toList();

SttBenchmarkRecorder enabledRecorder({
  required FakeBenchmarkClock clock,
  required CapturingBenchmarkSink sink,
  int maxCompletedSamples = 2048,
  int maxPendingUtterances = 256,
}) => SttBenchmarkRecorder(
  enabled: true,
  clock: clock,
  sink: sink,
  speechRmsThreshold: 1000,
  silenceRmsThreshold: 100,
  minimumSilenceDuration: const Duration(milliseconds: 20),
  minimumSilenceChunks: 2,
  maxCompletedSamples: maxCompletedSamples,
  maxPendingUtterances: maxPendingUtterances,
);

void establishSpeechOnset(
  SttBenchmarkRecorder recorder,
  FakeBenchmarkClock clock,
) {
  recorder.recordOutgoingPcm(pcmChunk(0));
  clock.advance(const Duration(milliseconds: 10));
  recorder.recordOutgoingPcm(pcmChunk(0));
  clock.advance(const Duration(milliseconds: 10));
  recorder.recordOutgoingPcm(pcmChunk(2000));
}

void main() {
  test('disabled recorder performs no RMS work and emits no output', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final rms = CountingRmsCalculator();
    final recorder = SttBenchmarkRecorder(
      enabled: false,
      clock: clock,
      sink: sink,
      rmsCalculator: rms,
    );

    recorder.sessionStartRequested();
    recorder.recordOutgoingPcm(pcmChunk(2000));
    recorder.recordTranscriptReceived(
      kind: SttBenchmarkTranscriptKind.interim,
      segmentId: 'segment-1',
    );
    recorder.stopped();

    expect(rms.calls, 0);
    expect(sink.lines, isEmpty);
    expect(recorder.hasPendingUiRender, isFalse);
  });

  test('runtime sink writes the filter prefix followed by one JSON object', () {
    final printed = <String>[];
    final sink = DebugPrintBenchmarkJsonlSink(printer: printed.add);

    sink.writeLine(
      '$sttBenchmarkLinePrefix'
      '{"category":"stt_benchmark","source":"mobile","event":"ready"}',
    );

    expect(printed, hasLength(1));
    expect(decodeLine(printed.single), {
      'category': 'stt_benchmark',
      'source': 'mobile',
      'event': 'ready',
    });
  });

  test('speech onset occurs once after configured prior silence', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = enabledRecorder(clock: clock, sink: sink);
    recorder.sessionStartRequested();

    establishSpeechOnset(recorder, clock);

    expect(eventsNamed(sink, 'speech_onset'), hasLength(1));
  });

  test('continuous loud chunks do not create repeated speech onsets', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = enabledRecorder(clock: clock, sink: sink);
    recorder.sessionStartRequested();
    establishSpeechOnset(recorder, clock);

    recorder.recordOutgoingPcm(pcmChunk(2500));
    recorder.recordOutgoingPcm(pcmChunk(3000));

    expect(eventsNamed(sink, 'speech_onset'), hasLength(1));
  });

  test('sufficient silence after speech arms the next utterance', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = enabledRecorder(clock: clock, sink: sink);
    recorder.sessionStartRequested();
    establishSpeechOnset(recorder, clock);

    recorder.recordOutgoingPcm(pcmChunk(0));
    recorder.recordOutgoingPcm(pcmChunk(0));
    recorder.recordOutgoingPcm(pcmChunk(2000));

    expect(eventsNamed(sink, 'speech_onset'), hasLength(2));
  });

  test('long pause with no PCM re-arms speech onset', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = enabledRecorder(clock: clock, sink: sink);
    recorder.sessionStartRequested();
    establishSpeechOnset(recorder, clock);
    recorder.paused();
    clock.advance(const Duration(milliseconds: 20));

    recorder.resumed();
    recorder.recordOutgoingPcm(pcmChunk(2000));

    expect(eventsNamed(sink, 'speech_onset'), hasLength(2));
  });

  test('resume makes the next speech a fresh utterance after any pause', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = enabledRecorder(clock: clock, sink: sink);
    recorder.sessionStartRequested();
    establishSpeechOnset(recorder, clock);
    recorder.paused();
    clock.advance(const Duration(milliseconds: 19));

    recorder.resumed();
    recorder.recordOutgoingPcm(pcmChunk(2000));

    expect(eventsNamed(sink, 'speech_onset'), hasLength(2));
  });

  test('pause retires a pending assigned utterance', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = enabledRecorder(clock: clock, sink: sink);
    recorder.sessionStartRequested();
    establishSpeechOnset(recorder, clock);
    clock.advance(const Duration(milliseconds: 10));
    recorder.recordTranscriptReceived(
      kind: SttBenchmarkTranscriptKind.interim,
      segmentId: 'segment-before-pause',
    );

    recorder.paused();
    clock.advance(const Duration(seconds: 15));
    recorder.recordTranscriptReceived(
      kind: SttBenchmarkTranscriptKind.finalResult,
      segmentId: 'segment-before-pause',
    );

    expect(eventsNamed(sink, 'speech_to_first_final'), isEmpty);
    expect(eventsNamed(sink, 'utterance_complete'), isEmpty);
  });

  test(
    'delayed unassigned result after pause is not attached to resumed speech',
    () {
      final clock = FakeBenchmarkClock();
      final sink = CapturingBenchmarkSink();
      final recorder = enabledRecorder(clock: clock, sink: sink);
      recorder.sessionStartRequested();
      establishSpeechOnset(recorder, clock);

      recorder.paused();
      clock.advance(const Duration(seconds: 15));
      recorder.resumed();
      recorder.recordOutgoingPcm(pcmChunk(2000));
      clock.advance(const Duration(milliseconds: 10));
      recorder.recordTranscriptReceived(
        kind: SttBenchmarkTranscriptKind.interim,
        segmentId: 'delayed-segment-a',
      );
      clock.advance(const Duration(milliseconds: 5));
      recorder.recordTranscriptReceived(
        kind: SttBenchmarkTranscriptKind.interim,
        segmentId: 'segment-b',
      );

      final metrics = eventsNamed(sink, 'speech_to_first_interim');
      expect(metrics, hasLength(1));
      expect(metrics.single['utterance_id'], 2);
      expect(metrics.single['speech_to_first_interim_ms'], 15);
    },
  );

  test('ambiguous result after pause produces no contaminated latency', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = enabledRecorder(clock: clock, sink: sink);
    recorder.sessionStartRequested();
    establishSpeechOnset(recorder, clock);

    recorder.paused();
    clock.advance(const Duration(milliseconds: 14500));
    recorder.resumed();
    recorder.recordOutgoingPcm(pcmChunk(2000));
    clock.advance(const Duration(milliseconds: 25));
    recorder.recordTranscriptReceived(
      kind: SttBenchmarkTranscriptKind.finalResult,
      segmentId: 'segment-after-pause',
    );
    recorder.stopped();

    final summary = eventsNamed(sink, 'summary').single;
    expect(summary['speech_to_first_final_ms'], {
      'count': 0,
      'min': null,
      'median': null,
      'p95': null,
      'max': null,
    });
  });

  test('long reconnect gap with no PCM re-arms speech onset', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = enabledRecorder(clock: clock, sink: sink);
    recorder.sessionStartRequested();
    establishSpeechOnset(recorder, clock);
    recorder.reconnectStarted();
    clock.advance(const Duration(milliseconds: 20));

    recorder.reconnectReady();
    recorder.recordOutgoingPcm(pcmChunk(2000));

    expect(eventsNamed(sink, 'speech_onset'), hasLength(2));
  });

  test('reconnect starts a fresh provider segment association namespace', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = enabledRecorder(clock: clock, sink: sink);
    recorder.sessionStartRequested();
    establishSpeechOnset(recorder, clock);
    clock.advance(const Duration(milliseconds: 10));
    recorder.recordTranscriptReceived(
      kind: SttBenchmarkTranscriptKind.finalResult,
      segmentId: 'seg_001',
    );

    recorder.reconnectStarted();
    clock.advance(const Duration(milliseconds: 20));
    recorder.reconnectReady();
    recorder.recordOutgoingPcm(pcmChunk(2000));
    clock.advance(const Duration(milliseconds: 15));
    recorder.recordTranscriptReceived(
      kind: SttBenchmarkTranscriptKind.finalResult,
      segmentId: 'seg_001',
    );

    expect(
      eventsNamed(
        sink,
        'utterance_complete',
      ).map((event) => event['utterance_id']),
      [1, 2],
    );
  });

  test('default onset silence exceeds a 300ms provider endpoint', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = SttBenchmarkRecorder(
      enabled: true,
      clock: clock,
      sink: sink,
    );
    recorder.sessionStartRequested();
    for (var index = 0; index < 7; index++) {
      recorder.recordOutgoingPcm(pcmChunk(0, sampleCount: 800));
    }
    recorder.recordOutgoingPcm(pcmChunk(2000));

    for (var index = 0; index < 5; index++) {
      recorder.recordOutgoingPcm(pcmChunk(0, sampleCount: 800));
    }
    recorder.recordOutgoingPcm(pcmChunk(2000));

    expect(eventsNamed(sink, 'speech_onset'), hasLength(1));
  });

  test('RMS inspection leaves outgoing PCM bytes exactly unchanged', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = enabledRecorder(clock: clock, sink: sink);
    final audio = Uint8List.fromList([0, 128, 255, 127, 52, 18, 204, 237]);
    final before = Uint8List.fromList(audio);

    recorder.recordOutgoingPcm(audio);

    expect(audio, orderedEquals(before));
  });

  test('first interim is recorded once for repeated events in one segment', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = enabledRecorder(clock: clock, sink: sink);
    recorder.sessionStartRequested();
    establishSpeechOnset(recorder, clock);
    clock.advance(const Duration(milliseconds: 30));

    recorder.recordTranscriptReceived(
      kind: SttBenchmarkTranscriptKind.interim,
      segmentId: 'segment-1',
    );
    clock.advance(const Duration(milliseconds: 40));
    recorder.recordTranscriptReceived(
      kind: SttBenchmarkTranscriptKind.interim,
      segmentId: 'segment-1',
    );

    final metrics = eventsNamed(sink, 'speech_to_first_interim');
    expect(metrics, hasLength(1));
    expect(metrics.single['speech_to_first_interim_ms'], 30);
  });

  test('final records speech-to-final and interim-to-final metrics', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = enabledRecorder(clock: clock, sink: sink);
    recorder.sessionStartRequested();
    establishSpeechOnset(recorder, clock);
    clock.advance(const Duration(milliseconds: 30));
    recorder.recordTranscriptReceived(
      kind: SttBenchmarkTranscriptKind.interim,
      segmentId: 'segment-1',
    );
    clock.advance(const Duration(milliseconds: 70));

    recorder.recordTranscriptReceived(
      kind: SttBenchmarkTranscriptKind.finalResult,
      segmentId: 'segment-1',
    );

    expect(
      eventsNamed(
        sink,
        'speech_to_first_final',
      ).single['speech_to_first_final_ms'],
      100,
    );
    expect(
      eventsNamed(sink, 'interim_to_final').single['interim_to_final_ms'],
      70,
    );
  });

  test('utterance events share a stable privacy-safe identifier', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = enabledRecorder(clock: clock, sink: sink);
    recorder.sessionStartRequested();
    establishSpeechOnset(recorder, clock);
    clock.advance(const Duration(milliseconds: 30));
    recorder.recordTranscriptReceived(
      kind: SttBenchmarkTranscriptKind.interim,
      segmentId: 'private-segment-id',
    );
    clock.advance(const Duration(milliseconds: 20));

    recorder.recordTranscriptReceived(
      kind: SttBenchmarkTranscriptKind.finalResult,
      segmentId: 'private-segment-id',
    );

    final onset = eventsNamed(sink, 'speech_onset').single;
    final interim = eventsNamed(sink, 'speech_to_first_interim').single;
    final finalMetric = eventsNamed(sink, 'speech_to_first_final').single;
    final interimToFinal = eventsNamed(sink, 'interim_to_final').single;
    final complete = eventsNamed(sink, 'utterance_complete').single;
    expect(onset['utterance_id'], 1);
    expect(interim['utterance_id'], onset['utterance_id']);
    expect(finalMetric['utterance_id'], onset['utterance_id']);
    expect(interimToFinal['utterance_id'], onset['utterance_id']);
    expect(complete, containsPair('utterance_id', onset['utterance_id']));
    expect(complete['speech_to_first_interim_ms'], 30);
    expect(complete['speech_to_first_final_ms'], 50);
    expect(complete['interim_to_final_ms'], 20);
    expect(sink.lines.join('\n'), isNot(contains('private-segment-id')));
  });

  test('final-only transcript safely records speech-to-final only', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = enabledRecorder(clock: clock, sink: sink);
    recorder.sessionStartRequested();
    establishSpeechOnset(recorder, clock);
    clock.advance(const Duration(milliseconds: 55));

    recorder.recordTranscriptReceived(
      kind: SttBenchmarkTranscriptKind.finalResult,
      segmentId: 'segment-final-only',
    );

    expect(
      eventsNamed(
        sink,
        'speech_to_first_final',
      ).single['speech_to_first_final_ms'],
      55,
    );
    expect(eventsNamed(sink, 'interim_to_final'), isEmpty);
  });

  test(
    'pause and reconnect durations appear in deterministic stop summary',
    () {
      final clock = FakeBenchmarkClock();
      final sink = CapturingBenchmarkSink();
      final recorder = enabledRecorder(clock: clock, sink: sink);
      recorder.sessionStartRequested();
      clock.advance(const Duration(milliseconds: 5));
      recorder.connectStarted();
      clock.advance(const Duration(milliseconds: 20));
      recorder.websocketReady();
      clock.advance(const Duration(milliseconds: 10));
      recorder.microphoneStarted();
      clock.advance(const Duration(milliseconds: 5));
      recorder.listeningStarted();
      clock.advance(const Duration(milliseconds: 60));
      recorder.paused();
      clock.advance(const Duration(milliseconds: 30));
      recorder.resumed();
      clock.advance(const Duration(milliseconds: 20));
      recorder.reconnectStarted();
      clock.advance(const Duration(milliseconds: 40));
      recorder.reconnectReady();
      clock.advance(const Duration(milliseconds: 60));

      recorder.stopped();

      expect(
        eventsNamed(sink, 'websocket_ready').single['connect_to_ready_ms'],
        20,
      );
      expect(
        eventsNamed(
          sink,
          'microphone_started',
        ).single['ready_to_microphone_ms'],
        10,
      );
      expect(
        eventsNamed(sink, 'listening_started').single['start_to_listening_ms'],
        40,
      );
      expect(eventsNamed(sink, 'resumed').single['pause_duration_ms'], 30);
      expect(
        eventsNamed(sink, 'reconnect_ready').single['reconnect_duration_ms'],
        40,
      );

      final summary = eventsNamed(sink, 'summary').single;
      expect(summary['utterance_count'], 0);
      expect(summary['pause_count'], 1);
      expect(summary['reconnect_count'], 1);
      expect(summary['session_duration_ms'], 250);
      expect(summary['error_count'], 0);
      expect(summary['pause_duration_ms'], {
        'count': 1,
        'min': 30,
        'median': 30,
        'p95': 30,
        'max': 30,
      });
      expect(summary['reconnect_duration_ms'], {
        'count': 1,
        'min': 40,
        'median': 40,
        'p95': 40,
        'max': 40,
      });
    },
  );

  test('retry after reconnect failure starts a distinct duration sample', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = enabledRecorder(clock: clock, sink: sink);
    recorder.sessionStartRequested();
    recorder.reconnectStarted();
    clock.advance(const Duration(milliseconds: 10));
    recorder.reconnectFailed();
    clock.advance(const Duration(milliseconds: 50));
    recorder.reconnectStarted();
    clock.advance(const Duration(milliseconds: 20));
    recorder.reconnectReady();

    recorder.stopped();

    final summary = eventsNamed(sink, 'summary').single;
    expect(summary['reconnect_count'], 2);
    expect(summary['reconnect_duration_ms'], {
      'count': 2,
      'min': 10,
      'median': 15,
      'p95': 20,
      'max': 20,
    });
  });

  test(
    'summary contains deterministic latency stats and no transcript data',
    () {
      final clock = FakeBenchmarkClock();
      final sink = CapturingBenchmarkSink();
      final recorder = enabledRecorder(clock: clock, sink: sink);
      recorder.sessionStartRequested();
      establishSpeechOnset(recorder, clock);
      clock.advance(const Duration(milliseconds: 25));
      recorder.recordTranscriptReceived(
        kind: SttBenchmarkTranscriptKind.interim,
        segmentId: 'private-segment',
      );
      clock.advance(const Duration(milliseconds: 15));
      recorder.recordTranscriptReceived(
        kind: SttBenchmarkTranscriptKind.finalResult,
        segmentId: 'private-segment',
      );
      recorder.recordUiRendered(recorder.latestTranscriptRevision);

      recorder.stopped();

      final summary = eventsNamed(sink, 'summary').single;
      expect(summary['speech_to_first_interim_ms'], {
        'count': 1,
        'min': 25,
        'median': 25,
        'p95': 25,
        'max': 25,
      });
      expect(summary['speech_to_first_final_ms'], {
        'count': 1,
        'min': 40,
        'median': 40,
        'p95': 40,
        'max': 40,
      });
      expect(summary['interim_to_final_ms'], {
        'count': 1,
        'min': 15,
        'median': 15,
        'p95': 15,
        'max': 15,
      });
      expect(sink.lines.join('\n'), isNot(contains('private-segment')));
    },
  );

  test('old post-frame revision cannot consume a new session receipt', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = enabledRecorder(clock: clock, sink: sink);
    recorder.sessionStartRequested();
    recorder.recordTranscriptReceived(
      kind: SttBenchmarkTranscriptKind.interim,
      segmentId: 'old-session-segment',
    );
    final oldRevision = recorder.latestTranscriptRevision;
    recorder.stopped();
    recorder.sessionStartRequested();
    recorder.recordTranscriptReceived(
      kind: SttBenchmarkTranscriptKind.interim,
      segmentId: 'new-session-segment',
    );

    recorder.recordUiRendered(oldRevision);

    expect(recorder.latestTranscriptRevision, greaterThan(oldRevision));
    expect(recorder.hasPendingUiRender, isTrue);
  });

  test('median and nearest-rank p95 are deterministic', () {
    final stats = BenchmarkStats.fromMilliseconds([1, 2, 3, 100]);

    expect(stats.toJson(), {
      'count': 4,
      'min': 1,
      'median': 2.5,
      'p95': 100,
      'max': 100,
    });
  });

  test('completed metric samples are capped for a long session', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = enabledRecorder(
      clock: clock,
      sink: sink,
      maxCompletedSamples: 3,
    );
    recorder.sessionStartRequested();
    for (var index = 1; index <= 5; index++) {
      establishSpeechOnset(recorder, clock);
      clock.advance(Duration(milliseconds: index));
      recorder.recordTranscriptReceived(
        kind: SttBenchmarkTranscriptKind.finalResult,
        segmentId: 'segment-$index',
      );
      recorder.recordOutgoingPcm(pcmChunk(0));
      recorder.recordOutgoingPcm(pcmChunk(0));
    }

    recorder.stopped();

    final stats =
        eventsNamed(sink, 'summary').single['speech_to_first_final_ms']
            as Map<String, Object?>;
    expect(stats['count'], 3);
  });

  test('delayed result for an evicted segment is not reassigned', () {
    final clock = FakeBenchmarkClock();
    final sink = CapturingBenchmarkSink();
    final recorder = enabledRecorder(
      clock: clock,
      sink: sink,
      maxPendingUtterances: 2,
    );
    recorder.sessionStartRequested();

    for (var index = 1; index <= 3; index++) {
      establishSpeechOnset(recorder, clock);
      if (index < 3) {
        recorder.recordTranscriptReceived(
          kind: SttBenchmarkTranscriptKind.interim,
          segmentId: 'segment-$index',
        );
      }
      recorder.recordOutgoingPcm(pcmChunk(0));
      recorder.recordOutgoingPcm(pcmChunk(0));
    }

    recorder.recordTranscriptReceived(
      kind: SttBenchmarkTranscriptKind.finalResult,
      segmentId: 'segment-1',
    );

    expect(eventsNamed(sink, 'utterance_complete'), isEmpty);

    recorder.recordTranscriptReceived(
      kind: SttBenchmarkTranscriptKind.finalResult,
      segmentId: 'segment-2',
    );
    recorder.recordTranscriptReceived(
      kind: SttBenchmarkTranscriptKind.finalResult,
      segmentId: 'segment-3',
    );
    expect(
      eventsNamed(
        sink,
        'utterance_complete',
      ).map((event) => event['utterance_id']),
      [2, 3],
    );
  });
}

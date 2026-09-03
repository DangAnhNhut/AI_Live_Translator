import 'dart:convert';

import 'package:ai_live_translator_mobile/diagnostics/stt_transcript_trace.dart';
import 'package:flutter_test/flutter_test.dart';

class CapturingTranscriptTraceSink implements SttTranscriptTraceJsonlSink {
  final List<String> lines = [];

  @override
  void writeLine(String line) => lines.add(line);
}

Map<String, Object?> decodeTraceLine(String line) {
  expect(line, startsWith(sttTranscriptTraceLinePrefix));
  return jsonDecode(line.substring(sttTranscriptTraceLinePrefix.length))
      as Map<String, Object?>;
}

void main() {
  test('disabled transcript trace emits no lines', () {
    final sink = CapturingTranscriptTraceSink();
    final trace = createSttTranscriptTrace(enabled: false, sink: sink);

    trace.websocketTranscriptReceived(
      sequence: 1,
      segmentId: 'segment-a',
      kind: 'interim',
      text: 'Xin',
      language: 'vi',
    );
    trace.segmentApplied(
      segmentId: 'segment-a',
      incomingKind: 'interim',
      previousText: null,
      resultingText: 'Xin',
      action: TranscriptSegmentAction.inserted,
    );
    trace.finalSegmentSnapshot(const [
      TranscriptTraceFinalSegment(segmentId: 'segment-a', text: 'Xin'),
    ]);

    expect(sink.lines, isEmpty);
  });

  test('enabled transcript trace emits structured JSON lines', () {
    final sink = CapturingTranscriptTraceSink();
    final trace = createSttTranscriptTrace(enabled: true, sink: sink);

    trace.websocketTranscriptReceived(
      sequence: 3,
      segmentId: 'segment-a',
      kind: 'final',
      text: 'Xin chao.',
      language: 'vi',
    );
    trace.segmentApplied(
      segmentId: 'segment-a',
      incomingKind: 'final',
      previousText: 'Xin',
      resultingText: 'Xin chao.',
      action: TranscriptSegmentAction.finalized,
    );
    trace.finalSegmentSnapshot(const [
      TranscriptTraceFinalSegment(segmentId: 'segment-a', text: 'Xin chao.'),
    ]);

    expect(sink.lines, hasLength(3));
    expect(decodeTraceLine(sink.lines[0]), {
      'category': 'stt_transcript_trace',
      'source': 'mobile',
      'event': 'websocket_transcript_received',
      'receive_sequence': 3,
      'segment_id': 'segment-a',
      'kind': 'final',
      'text': 'Xin chao.',
      'language': 'vi',
    });
    expect(decodeTraceLine(sink.lines[1]), {
      'category': 'stt_transcript_trace',
      'source': 'mobile',
      'event': 'segment_applied',
      'segment_id': 'segment-a',
      'incoming_kind': 'final',
      'previous_text': 'Xin',
      'resulting_text': 'Xin chao.',
      'action': 'finalized',
    });
    expect(decodeTraceLine(sink.lines[2]), {
      'category': 'stt_transcript_trace',
      'source': 'mobile',
      'event': 'final_segment_snapshot',
      'segments': [
        {'segment_id': 'segment-a', 'text': 'Xin chao.'},
      ],
    });
  });
}

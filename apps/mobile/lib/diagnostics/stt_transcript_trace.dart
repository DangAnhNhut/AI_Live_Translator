import 'dart:convert';

import 'package:flutter/foundation.dart';

const String sttTranscriptTraceLinePrefix = 'STT_TRANSCRIPT_TRACE ';

enum TranscriptSegmentAction { inserted, revised, finalized, ignored }

class TranscriptTraceFinalSegment {
  const TranscriptTraceFinalSegment({
    required this.segmentId,
    required this.text,
  });

  final String segmentId;
  final String text;

  Map<String, Object?> toJson() => {'segment_id': segmentId, 'text': text};
}

abstract interface class SttTranscriptTraceJsonlSink {
  void writeLine(String line);
}

class DebugPrintSttTranscriptTraceJsonlSink
    implements SttTranscriptTraceJsonlSink {
  const DebugPrintSttTranscriptTraceJsonlSink();

  @override
  void writeLine(String line) => debugPrint(line);
}

abstract interface class SttTranscriptTrace {
  void websocketTranscriptReceived({
    required int sequence,
    required String segmentId,
    required String kind,
    required String text,
    required String language,
  });

  void segmentApplied({
    required String segmentId,
    required String incomingKind,
    required String? previousText,
    required String resultingText,
    required TranscriptSegmentAction action,
  });

  void finalSegmentSnapshot(List<TranscriptTraceFinalSegment> segments);
}

SttTranscriptTrace createSttTranscriptTrace({
  required bool enabled,
  SttTranscriptTraceJsonlSink? sink,
}) {
  if (!enabled) {
    return const DisabledSttTranscriptTrace();
  }
  return JsonlSttTranscriptTrace(
    sink: sink ?? const DebugPrintSttTranscriptTraceJsonlSink(),
  );
}

class DisabledSttTranscriptTrace implements SttTranscriptTrace {
  const DisabledSttTranscriptTrace();

  @override
  void finalSegmentSnapshot(List<TranscriptTraceFinalSegment> segments) {}

  @override
  void segmentApplied({
    required String segmentId,
    required String incomingKind,
    required String? previousText,
    required String resultingText,
    required TranscriptSegmentAction action,
  }) {}

  @override
  void websocketTranscriptReceived({
    required int sequence,
    required String segmentId,
    required String kind,
    required String text,
    required String language,
  }) {}
}

class JsonlSttTranscriptTrace implements SttTranscriptTrace {
  JsonlSttTranscriptTrace({required SttTranscriptTraceJsonlSink sink})
    : _sink = sink;

  final SttTranscriptTraceJsonlSink _sink;

  @override
  void websocketTranscriptReceived({
    required int sequence,
    required String segmentId,
    required String kind,
    required String text,
    required String language,
  }) {
    _emit('websocket_transcript_received', {
      'receive_sequence': sequence,
      'segment_id': segmentId,
      'kind': kind,
      'text': text,
      'language': language,
    });
  }

  @override
  void segmentApplied({
    required String segmentId,
    required String incomingKind,
    required String? previousText,
    required String resultingText,
    required TranscriptSegmentAction action,
  }) {
    _emit('segment_applied', {
      'segment_id': segmentId,
      'incoming_kind': incomingKind,
      'previous_text': previousText,
      'resulting_text': resultingText,
      'action': action.name,
    });
  }

  @override
  void finalSegmentSnapshot(List<TranscriptTraceFinalSegment> segments) {
    _emit('final_segment_snapshot', {
      'segments': segments.map((segment) => segment.toJson()).toList(),
    });
  }

  void _emit(String event, Map<String, Object?> fields) {
    _sink.writeLine(
      '$sttTranscriptTraceLinePrefix'
      '${jsonEncode({'category': 'stt_transcript_trace', 'source': 'mobile', 'event': event, ...fields})}',
    );
  }
}

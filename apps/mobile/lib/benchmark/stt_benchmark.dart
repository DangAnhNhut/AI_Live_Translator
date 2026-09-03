import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

const String sttBenchmarkLinePrefix = 'STT_BENCHMARK ';

abstract interface class BenchmarkElapsedClock {
  Duration get elapsed;
}

class StopwatchBenchmarkElapsedClock implements BenchmarkElapsedClock {
  StopwatchBenchmarkElapsedClock() : _stopwatch = Stopwatch()..start();

  final Stopwatch _stopwatch;

  @override
  Duration get elapsed => _stopwatch.elapsed;
}

abstract interface class BenchmarkJsonlSink {
  void writeLine(String line);
}

typedef BenchmarkLinePrinter = void Function(String line);

class DebugPrintBenchmarkJsonlSink implements BenchmarkJsonlSink {
  DebugPrintBenchmarkJsonlSink({BenchmarkLinePrinter? printer})
    : _printer = printer ?? debugPrint;

  final BenchmarkLinePrinter _printer;

  @override
  void writeLine(String line) => _printer(line);
}

abstract interface class PcmRmsCalculator {
  double calculateS16le(Uint8List pcm);
}

class S16lePcmRmsCalculator implements PcmRmsCalculator {
  const S16lePcmRmsCalculator();

  @override
  double calculateS16le(Uint8List pcm) {
    final sampleCount = pcm.lengthInBytes ~/ 2;
    if (sampleCount == 0) {
      return 0;
    }
    final samples = ByteData.sublistView(pcm);
    var sumOfSquares = 0;
    for (var index = 0; index < sampleCount; index++) {
      final sample = samples.getInt16(index * 2, Endian.little);
      sumOfSquares += sample * sample;
    }
    return math.sqrt(sumOfSquares / sampleCount);
  }
}

enum SttBenchmarkTranscriptKind { interim, finalResult }

abstract interface class LiveSessionBenchmark {
  bool get enabled;
  bool get hasPendingUiRender;
  int get latestTranscriptRevision;

  void sessionStartRequested();
  void connectStarted();
  void websocketReady();
  void microphoneStarted();
  void listeningStarted();
  void paused();
  void resumed();
  void reconnectStarted();
  void reconnectReady();
  void reconnectFailed();
  void stopped();
  void recordError();
  void recordOutgoingPcm(Uint8List pcm);
  void recordTranscriptReceived({
    required SttBenchmarkTranscriptKind kind,
    required String segmentId,
  });
  void recordUiRendered(int transcriptRevision);
}

class DisabledLiveSessionBenchmark implements LiveSessionBenchmark {
  const DisabledLiveSessionBenchmark();

  @override
  bool get enabled => false;

  @override
  bool get hasPendingUiRender => false;

  @override
  int get latestTranscriptRevision => 0;

  @override
  void connectStarted() {}

  @override
  void listeningStarted() {}

  @override
  void microphoneStarted() {}

  @override
  void paused() {}

  @override
  void reconnectReady() {}

  @override
  void reconnectFailed() {}

  @override
  void reconnectStarted() {}

  @override
  void recordError() {}

  @override
  void recordOutgoingPcm(Uint8List pcm) {}

  @override
  void recordTranscriptReceived({
    required SttBenchmarkTranscriptKind kind,
    required String segmentId,
  }) {}

  @override
  void recordUiRendered(int transcriptRevision) {}

  @override
  void resumed() {}

  @override
  void sessionStartRequested() {}

  @override
  void stopped() {}

  @override
  void websocketReady() {}
}

class BenchmarkStats {
  BenchmarkStats._(this.count, this.min, this.median, this.p95, this.max);

  factory BenchmarkStats.fromMilliseconds(Iterable<int> samples) {
    final sorted = samples.toList()..sort();
    if (sorted.isEmpty) {
      return BenchmarkStats._(0, null, null, null, null);
    }
    final middle = sorted.length ~/ 2;
    final num median = sorted.length.isOdd
        ? sorted[middle]
        : (sorted[middle - 1] + sorted[middle]) / 2;
    // Nearest-rank p95: sorted[ceil(0.95 * N) - 1].
    final p95Index = (0.95 * sorted.length).ceil() - 1;
    return BenchmarkStats._(
      sorted.length,
      sorted.first,
      median,
      sorted[p95Index],
      sorted.last,
    );
  }

  final int count;
  final int? min;
  final num? median;
  final int? p95;
  final int? max;

  Map<String, Object?> toJson() => {
    'count': count,
    'min': min,
    'median': median,
    'p95': p95,
    'max': max,
  };
}

class SttBenchmarkRecorder implements LiveSessionBenchmark {
  SttBenchmarkRecorder({
    required this.enabled,
    required BenchmarkElapsedClock clock,
    required BenchmarkJsonlSink sink,
    PcmRmsCalculator? rmsCalculator,
    this.speechRmsThreshold = 1200,
    this.silenceRmsThreshold = 400,
    this.minimumSilenceDuration = const Duration(milliseconds: 350),
    this.minimumSilenceChunks = 3,
    this.maxCompletedSamples = 2048,
    this.maxPendingUtterances = 256,
  }) : _clock = clock,
       _sink = sink,
       _rmsCalculator = rmsCalculator ?? const S16lePcmRmsCalculator(),
       assert(speechRmsThreshold > silenceRmsThreshold),
       assert(silenceRmsThreshold >= 0),
       assert(minimumSilenceDuration >= Duration.zero),
       assert(minimumSilenceChunks > 0),
       assert(maxCompletedSamples > 0),
       assert(maxPendingUtterances > 0);

  static const int _sampleRate = 16000;

  @override
  final bool enabled;
  final BenchmarkElapsedClock _clock;
  final BenchmarkJsonlSink _sink;
  final PcmRmsCalculator _rmsCalculator;
  final double speechRmsThreshold;
  final double silenceRmsThreshold;
  final Duration minimumSilenceDuration;
  final int minimumSilenceChunks;
  final int maxCompletedSamples;
  final int maxPendingUtterances;

  Duration? _sessionStartedAt;
  Duration? _connectStartedAt;
  Duration? _websocketReadyAt;
  Duration? _pausedAt;
  Duration? _reconnectStartedAt;
  Duration? _lastPcmAt;
  Duration _silenceDuration = Duration.zero;
  int _silenceChunks = 0;
  bool _speechActive = false;
  bool _speechArmed = false;
  int _utteranceCount = 0;
  int _pauseCount = 0;
  int _reconnectCount = 0;
  int _errorCount = 0;
  int _latestTranscriptRevision = 0;
  final List<_BenchmarkUtterance> _utterances = [];
  final Map<String, _BenchmarkUtterance> _segmentUtterances = {};
  final Set<String> _retiredSegmentIds = {};
  final List<String> _retiredSegmentOrder = [];
  int _ambiguousUnassignedResults = 0;
  final List<_UiReceipt> _pendingUiReceipts = [];
  final List<int> _speechToFirstInterim = [];
  final List<int> _speechToFirstFinal = [];
  final List<int> _interimToFinal = [];
  final List<int> _receiveToUiRender = [];
  final List<int> _pauseDurations = [];
  final List<int> _reconnectDurations = [];

  @override
  bool get hasPendingUiRender => enabled && _pendingUiReceipts.isNotEmpty;

  @override
  int get latestTranscriptRevision => enabled ? _latestTranscriptRevision : 0;

  @override
  void sessionStartRequested() {
    if (!enabled) {
      return;
    }
    _resetSession();
    _sessionStartedAt = _clock.elapsed;
    _emit('session_start_requested');
  }

  @override
  void connectStarted() {
    if (!enabled || _sessionStartedAt == null) {
      return;
    }
    _connectStartedAt = _clock.elapsed;
  }

  @override
  void websocketReady() {
    if (!enabled || _sessionStartedAt == null) {
      return;
    }
    final now = _clock.elapsed;
    _websocketReadyAt = now;
    _emit('websocket_ready', {
      'connect_to_ready_ms': _elapsedMilliseconds(_connectStartedAt, now),
    });
  }

  @override
  void microphoneStarted() {
    if (!enabled || _sessionStartedAt == null) {
      return;
    }
    final now = _clock.elapsed;
    _emit('microphone_started', {
      'ready_to_microphone_ms': _elapsedMilliseconds(_websocketReadyAt, now),
    });
  }

  @override
  void listeningStarted() {
    if (!enabled || _sessionStartedAt == null) {
      return;
    }
    final now = _clock.elapsed;
    _emit('listening_started', {
      'start_to_listening_ms': _elapsedMilliseconds(_sessionStartedAt, now),
    });
  }

  @override
  void paused() {
    if (!enabled || _sessionStartedAt == null || _pausedAt != null) {
      return;
    }
    _pausedAt = _clock.elapsed;
    _pauseCount++;
    _retirePendingUtterancesAtPause();
    _speechActive = false;
    _speechArmed = false;
    _resetSilenceRun();
    _emit('paused');
  }

  @override
  void resumed() {
    if (!enabled || _sessionStartedAt == null) {
      return;
    }
    final now = _clock.elapsed;
    final duration = _elapsedMilliseconds(_pausedAt, now);
    if (duration != null) {
      _appendBounded(_pauseDurations, duration);
    }
    _pausedAt = null;
    _speechActive = false;
    _speechArmed = true;
    _resetSilenceRun();
    _emit('resumed', {'pause_duration_ms': duration});
  }

  @override
  void reconnectStarted() {
    if (!enabled || _sessionStartedAt == null || _reconnectStartedAt != null) {
      return;
    }
    _reconnectStartedAt = _clock.elapsed;
    _reconnectCount++;
    _utterances.clear();
    _segmentUtterances.clear();
    _retiredSegmentIds.clear();
    _retiredSegmentOrder.clear();
    _ambiguousUnassignedResults = 0;
    _emit('reconnect_started');
  }

  @override
  void reconnectReady() {
    if (!enabled || _sessionStartedAt == null) {
      return;
    }
    final now = _clock.elapsed;
    final duration = _elapsedMilliseconds(_reconnectStartedAt, now);
    if (duration != null) {
      _appendBounded(_reconnectDurations, duration);
    }
    _reconnectStartedAt = null;
    _rearmAfterNoPcmGap(now);
    _emit('reconnect_ready', {'reconnect_duration_ms': duration});
  }

  @override
  void reconnectFailed() {
    if (!enabled || _sessionStartedAt == null) {
      return;
    }
    final now = _clock.elapsed;
    final duration = _elapsedMilliseconds(_reconnectStartedAt, now);
    if (duration != null) {
      _appendBounded(_reconnectDurations, duration);
    }
    _reconnectStartedAt = null;
  }

  @override
  void recordError() {
    if (!enabled || _sessionStartedAt == null) {
      return;
    }
    _errorCount++;
    _emit('error', {'error_count': _errorCount});
  }

  @override
  void recordOutgoingPcm(Uint8List pcm) {
    if (!enabled || _sessionStartedAt == null) {
      return;
    }
    final now = _clock.elapsed;
    _lastPcmAt = now;
    final rms = _rmsCalculator.calculateS16le(pcm);
    final chunkDuration = Duration(
      microseconds:
          ((pcm.lengthInBytes ~/ 2) * Duration.microsecondsPerSecond) ~/
          _sampleRate,
    );
    if (rms <= silenceRmsThreshold) {
      _silenceChunks++;
      _silenceDuration += chunkDuration;
      if (_silenceChunks >= minimumSilenceChunks &&
          _silenceDuration >= minimumSilenceDuration) {
        _speechActive = false;
        _speechArmed = true;
      }
      return;
    }
    if (rms < speechRmsThreshold) {
      _resetSilenceRun();
      return;
    }
    if (!_speechActive && _speechArmed) {
      _speechActive = true;
      _speechArmed = false;
      _utteranceCount++;
      _utterances.add(_BenchmarkUtterance(id: _utteranceCount, onsetAt: now));
      _capPendingUtterances();
      _emit('speech_onset', {'utterance_id': _utteranceCount});
    }
    _resetSilenceRun();
  }

  @override
  void recordTranscriptReceived({
    required SttBenchmarkTranscriptKind kind,
    required String segmentId,
  }) {
    if (!enabled || _sessionStartedAt == null) {
      return;
    }
    final now = _clock.elapsed;
    _latestTranscriptRevision++;
    _pendingUiReceipts.add(_UiReceipt(_latestTranscriptRevision, now));
    if (_pendingUiReceipts.length > maxPendingUtterances) {
      _pendingUiReceipts.removeAt(0);
    }

    if (_retiredSegmentIds.contains(segmentId)) {
      if (kind == SttBenchmarkTranscriptKind.finalResult) {
        _forgetRetiredSegment(segmentId);
      }
      return;
    }

    if (!_segmentUtterances.containsKey(segmentId) &&
        _ambiguousUnassignedResults > 0) {
      _ambiguousUnassignedResults--;
      if (kind == SttBenchmarkTranscriptKind.interim) {
        _retireSegment(segmentId);
      }
      return;
    }

    final utterance = _utteranceForSegment(segmentId);
    if (utterance == null) {
      return;
    }
    if (kind == SttBenchmarkTranscriptKind.interim) {
      if (utterance.firstInterimAt != null) {
        return;
      }
      utterance.firstInterimAt = now;
      final duration = (now - utterance.onsetAt).inMilliseconds;
      _appendBounded(_speechToFirstInterim, duration);
      _emit('speech_to_first_interim', {
        'utterance_id': utterance.id,
        'speech_to_first_interim_ms': duration,
      });
      return;
    }
    if (utterance.finalAt != null) {
      return;
    }
    utterance.finalAt = now;
    final speechToFinal = (now - utterance.onsetAt).inMilliseconds;
    _appendBounded(_speechToFirstFinal, speechToFinal);
    _emit('speech_to_first_final', {
      'utterance_id': utterance.id,
      'speech_to_first_final_ms': speechToFinal,
    });
    final interimAt = utterance.firstInterimAt;
    int? interimToFinal;
    if (interimAt != null) {
      interimToFinal = (now - interimAt).inMilliseconds;
      _appendBounded(_interimToFinal, interimToFinal);
      _emit('interim_to_final', {
        'utterance_id': utterance.id,
        'interim_to_final_ms': interimToFinal,
      });
    }
    _emit('utterance_complete', {
      'utterance_id': utterance.id,
      if (interimAt != null)
        'speech_to_first_interim_ms':
            (interimAt - utterance.onsetAt).inMilliseconds,
      'speech_to_first_final_ms': speechToFinal,
      'interim_to_final_ms': ?interimToFinal,
    });
  }

  @override
  void recordUiRendered(int transcriptRevision) {
    if (!enabled || _sessionStartedAt == null || _pendingUiReceipts.isEmpty) {
      return;
    }
    final now = _clock.elapsed;
    final rendered = _pendingUiReceipts
        .where((receipt) => receipt.revision <= transcriptRevision)
        .toList();
    _pendingUiReceipts.removeWhere(
      (receipt) => receipt.revision <= transcriptRevision,
    );
    for (final receipt in rendered) {
      final duration = (now - receipt.receivedAt).inMilliseconds;
      _appendBounded(_receiveToUiRender, duration);
      _emit('mobile_receive_to_ui_render', {
        'mobile_receive_to_ui_render_ms': duration,
      });
    }
  }

  @override
  void stopped() {
    if (!enabled || _sessionStartedAt == null) {
      return;
    }
    final now = _clock.elapsed;
    _finalizeOpenDurations(now);
    final sessionDuration = (now - _sessionStartedAt!).inMilliseconds;
    _emit('stopped', {'session_duration_ms': sessionDuration});
    _emit('summary', {
      'utterance_count': _utteranceCount,
      'speech_to_first_interim_ms': _stats(_speechToFirstInterim),
      'speech_to_first_final_ms': _stats(_speechToFirstFinal),
      'interim_to_final_ms': _stats(_interimToFinal),
      'mobile_receive_to_ui_render_ms': _stats(_receiveToUiRender),
      'reconnect_count': _reconnectCount,
      'reconnect_duration_ms': _stats(_reconnectDurations),
      'pause_count': _pauseCount,
      'pause_duration_ms': _stats(_pauseDurations),
      'session_duration_ms': sessionDuration,
      'error_count': _errorCount,
    });
    _resetSession();
  }

  _BenchmarkUtterance? _utteranceForSegment(String segmentId) {
    final existing = _segmentUtterances[segmentId];
    if (existing != null) {
      return existing;
    }
    for (final utterance in _utterances) {
      if (utterance.segmentId == null && utterance.finalAt == null) {
        utterance.segmentId = segmentId;
        _segmentUtterances[segmentId] = utterance;
        return utterance;
      }
    }
    return null;
  }

  void _capPendingUtterances() {
    while (_utterances.length > maxPendingUtterances) {
      final removed = _utterances.removeAt(0);
      final segmentId = removed.segmentId;
      if (segmentId != null &&
          identical(_segmentUtterances[segmentId], removed)) {
        _segmentUtterances.remove(segmentId);
        _retireSegment(segmentId);
      }
    }
  }

  void _retirePendingUtterancesAtPause() {
    var unassigned = 0;
    final pending = _utterances
        .where((utterance) => utterance.finalAt == null)
        .toList();
    for (final utterance in pending) {
      _utterances.remove(utterance);
      final segmentId = utterance.segmentId;
      if (segmentId == null) {
        unassigned++;
        continue;
      }
      if (identical(_segmentUtterances[segmentId], utterance)) {
        _segmentUtterances.remove(segmentId);
        _retireSegment(segmentId);
      }
    }
    _ambiguousUnassignedResults = math.min(
      maxPendingUtterances,
      _ambiguousUnassignedResults + unassigned,
    );
  }

  void _retireSegment(String segmentId) {
    if (_retiredSegmentIds.contains(segmentId)) {
      return;
    }
    if (_retiredSegmentOrder.length == maxPendingUtterances) {
      _retiredSegmentIds.remove(_retiredSegmentOrder.removeAt(0));
    }
    _retiredSegmentOrder.add(segmentId);
    _retiredSegmentIds.add(segmentId);
  }

  void _forgetRetiredSegment(String segmentId) {
    _retiredSegmentIds.remove(segmentId);
    _retiredSegmentOrder.remove(segmentId);
  }

  void _appendBounded(List<int> samples, int value) {
    if (samples.length == maxCompletedSamples) {
      samples.removeAt(0);
    }
    samples.add(value);
  }

  Map<String, Object?> _stats(List<int> samples) =>
      BenchmarkStats.fromMilliseconds(samples).toJson();

  int? _elapsedMilliseconds(Duration? start, Duration end) =>
      start == null ? null : (end - start).inMilliseconds;

  void _finalizeOpenDurations(Duration now) {
    final pauseDuration = _elapsedMilliseconds(_pausedAt, now);
    if (pauseDuration != null) {
      _appendBounded(_pauseDurations, pauseDuration);
      _pausedAt = null;
    }
    final reconnectDuration = _elapsedMilliseconds(_reconnectStartedAt, now);
    if (reconnectDuration != null) {
      _appendBounded(_reconnectDurations, reconnectDuration);
      _reconnectStartedAt = null;
    }
  }

  void _resetSilenceRun() {
    _silenceChunks = 0;
    _silenceDuration = Duration.zero;
  }

  void _rearmAfterNoPcmGap(Duration now) {
    final lastPcmAt = _lastPcmAt;
    if (lastPcmAt == null || now - lastPcmAt < minimumSilenceDuration) {
      return;
    }
    _speechActive = false;
    _speechArmed = true;
    _resetSilenceRun();
  }

  void _emit(String event, [Map<String, Object?> fields = const {}]) {
    _sink.writeLine(
      '$sttBenchmarkLinePrefix${jsonEncode({'category': 'stt_benchmark', 'source': 'mobile', 'event': event, ...fields})}',
    );
  }

  void _resetSession() {
    _sessionStartedAt = null;
    _connectStartedAt = null;
    _websocketReadyAt = null;
    _pausedAt = null;
    _reconnectStartedAt = null;
    _lastPcmAt = null;
    _resetSilenceRun();
    _speechActive = false;
    _speechArmed = false;
    _utteranceCount = 0;
    _pauseCount = 0;
    _reconnectCount = 0;
    _errorCount = 0;
    _utterances.clear();
    _segmentUtterances.clear();
    _retiredSegmentIds.clear();
    _retiredSegmentOrder.clear();
    _ambiguousUnassignedResults = 0;
    _pendingUiReceipts.clear();
    _speechToFirstInterim.clear();
    _speechToFirstFinal.clear();
    _interimToFinal.clear();
    _receiveToUiRender.clear();
    _pauseDurations.clear();
    _reconnectDurations.clear();
  }
}

class _BenchmarkUtterance {
  _BenchmarkUtterance({required this.id, required this.onsetAt});

  final int id;
  final Duration onsetAt;
  String? segmentId;
  Duration? firstInterimAt;
  Duration? finalAt;
}

class _UiReceipt {
  const _UiReceipt(this.revision, this.receivedAt);

  final int revision;
  final Duration receivedAt;
}

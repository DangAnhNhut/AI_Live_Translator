import 'dart:async';
import 'dart:convert';

import 'package:ai_live_translator_mobile/diagnostics/stt_transcript_trace.dart';
import 'package:ai_live_translator_mobile/services/audio_input.dart';
import 'package:ai_live_translator_mobile/services/microphone_capture_service.dart';
import 'package:ai_live_translator_mobile/services/microphone_permission_service.dart';
import 'package:ai_live_translator_mobile/services/stt_websocket_service.dart';
import 'package:ai_live_translator_mobile/session/live_session_controller.dart';
import 'package:ai_live_translator_mobile/session/live_session_state.dart';
import 'package:ai_live_translator_mobile/session/session_timer.dart';
import 'package:ai_live_translator_mobile/translation/translation_domain.dart';
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
  FakeSttSessionTransport({List<String>? operations})
    : operations = operations ?? <String>[];

  Completer<void>? pendingConnect;
  Completer<void>? pendingDisconnect;
  Completer<void>? pendingStop;
  Object? connectError;
  int connectCalls = 0;
  int stopCalls = 0;
  int disconnectCalls = 0;
  final List<String> operations;
  final List<Uint8List> sentAudio = [];
  final List<Completer<void>> sendAudioGates = [];
  Object? sendAudioError;
  int activeAudioSends = 0;
  int maxActiveAudioSends = 0;
  final List<Future<void>> connectResults = [];
  final List<SttSessionStartOptions> connectOptions = [];
  final StreamController<SttSessionEvent> eventController =
      StreamController<SttSessionEvent>.broadcast();

  @override
  Stream<SttSessionEvent> get events => eventController.stream;

  @override
  Future<void> connect({
    SttSessionStartOptions options = const SttSessionStartOptions(),
  }) async {
    connectCalls++;
    connectOptions.add(options);
    if (connectResults.isNotEmpty) {
      await connectResults.removeAt(0);
    }
    await pendingConnect?.future;
    if (connectError != null) {
      throw connectError!;
    }
  }

  @override
  Future<void> sendAudio(Uint8List audio) async {
    operations.add('transport.sendAudio');
    final sendIndex = sentAudio.length;
    sentAudio.add(audio);
    activeAudioSends++;
    maxActiveAudioSends = maxActiveAudioSends < activeAudioSends
        ? activeAudioSends
        : maxActiveAudioSends;
    try {
      if (sendIndex < sendAudioGates.length) {
        await sendAudioGates[sendIndex].future;
      }
      if (sendAudioError != null) {
        throw sendAudioError!;
      }
    } finally {
      activeAudioSends--;
    }
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    operations.add('transport.disconnect');
    await pendingDisconnect?.future;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    operations.add('transport.stop');
    await pendingStop?.future;
  }
}

class FakeMobileMicrophoneCapture implements MobileMicrophoneCapture {
  FakeMobileMicrophoneCapture({List<String>? operations})
    : operations = operations ?? <String>[] {
    audioController = StreamController<Uint8List>(
      sync: true,
      onListen: () {
        listenCalls++;
        this.operations.add('microphone.listen');
      },
      onCancel: () {
        cancelCalls++;
        this.operations.add('microphone.cancel');
      },
    );
  }

  final List<String> operations;
  late final StreamController<Uint8List> audioController;
  Completer<Stream<Uint8List>>? pendingStart;
  Completer<void>? pendingPause;
  Completer<void>? pendingResume;
  Object? startError;
  int startCalls = 0;
  int listenCalls = 0;
  int cancelCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;

  @override
  Future<Stream<Uint8List>> start() async {
    startCalls++;
    operations.add('microphone.start');
    if (startError != null) {
      throw startError!;
    }
    final pending = pendingStart;
    if (pending != null) {
      return pending.future;
    }
    return audioController.stream;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    operations.add('microphone.pause');
    await pendingPause?.future;
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
    operations.add('microphone.resume');
    await pendingResume?.future;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    operations.add('microphone.stop');
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    operations.add('microphone.dispose');
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

class TranscriptHarness {
  TranscriptHarness._(this.transport, this.controller);

  factory TranscriptHarness({
    SttTranscriptTrace transcriptTrace = const DisabledSttTranscriptTrace(),
  }) {
    final transport = FakeSttSessionTransport();
    return TranscriptHarness._(
      transport,
      LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        transcriptTrace: transcriptTrace,
      ),
    );
  }

  final FakeSttSessionTransport transport;
  final LiveSessionController controller;

  Future<void> emit({
    required SttTranscriptKind kind,
    required String segmentId,
    required String text,
  }) async {
    transport.eventController.add(
      SttTranscriptEvent(
        kind: kind,
        segmentId: segmentId,
        text: text,
        language: 'vi',
      ),
    );
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> dispose() async {
    controller.dispose();
    await transport.eventController.close();
  }
}

class CapturingControllerTranscriptTraceSink
    implements SttTranscriptTraceJsonlSink {
  final List<String> lines = [];

  @override
  void writeLine(String line) => lines.add(line);
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

    await controller.resume();
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

  test('interim transcript is visible for its segment', () async {
    final harness = TranscriptHarness();

    await harness.emit(
      kind: SttTranscriptKind.interim,
      segmentId: 'segment-a',
      text: 'Xin',
    );

    expect(harness.controller.transcript, 'Xin');
    await harness.dispose();
  });

  test('newer interim revises only the matching segment', () async {
    final harness = TranscriptHarness();
    await harness.emit(
      kind: SttTranscriptKind.interim,
      segmentId: 'segment-a',
      text: 'Xin',
    );

    await harness.emit(
      kind: SttTranscriptKind.interim,
      segmentId: 'segment-a',
      text: 'Xin chao',
    );

    expect(harness.controller.transcript, 'Xin chao');
    await harness.dispose();
  });

  test('final replaces the matching interim and remains visible', () async {
    final harness = TranscriptHarness();
    await harness.emit(
      kind: SttTranscriptKind.interim,
      segmentId: 'segment-a',
      text: 'Xin',
    );

    await harness.emit(
      kind: SttTranscriptKind.finalResult,
      segmentId: 'segment-a',
      text: 'Xin chao.',
    );

    expect(harness.controller.transcript, 'Xin chao.');
    await harness.dispose();
  });

  test('new segment does not delete an earlier final segment', () async {
    final harness = TranscriptHarness();
    await harness.emit(
      kind: SttTranscriptKind.finalResult,
      segmentId: 'segment-a',
      text: 'Cau dau.',
    );

    await harness.emit(
      kind: SttTranscriptKind.interim,
      segmentId: 'segment-b',
      text: 'Cau sau',
    );

    expect(harness.controller.transcript, 'Cau dau.\nCau sau');
    await harness.dispose();
  });

  test('empty late interim cannot erase a finalized segment', () async {
    final harness = TranscriptHarness();
    await harness.emit(
      kind: SttTranscriptKind.finalResult,
      segmentId: 'segment-a',
      text: 'Ban ghi da chot.',
    );

    await harness.emit(
      kind: SttTranscriptKind.interim,
      segmentId: 'segment-a',
      text: '',
    );

    expect(harness.controller.transcript, 'Ban ghi da chot.');
    await harness.dispose();
  });

  test('duplicate final is idempotent', () async {
    final harness = TranscriptHarness();
    await harness.emit(
      kind: SttTranscriptKind.finalResult,
      segmentId: 'segment-a',
      text: 'Ban ghi da chot.',
    );

    await harness.emit(
      kind: SttTranscriptKind.finalResult,
      segmentId: 'segment-a',
      text: 'Noi dung trung lap khac.',
    );

    expect(harness.controller.transcript, 'Ban ghi da chot.');
    await harness.dispose();
  });

  test('later events cannot overwrite a different segment', () async {
    final harness = TranscriptHarness();
    await harness.emit(
      kind: SttTranscriptKind.interim,
      segmentId: 'segment-a',
      text: 'A ban dau',
    );
    await harness.emit(
      kind: SttTranscriptKind.interim,
      segmentId: 'segment-b',
      text: 'B khong doi',
    );

    await harness.emit(
      kind: SttTranscriptKind.interim,
      segmentId: 'segment-a',
      text: 'A sua doi',
    );

    expect(harness.controller.transcript, 'A sua doi\nB khong doi');
    await harness.dispose();
  });

  test('finalized segments stay ordered through continued speech', () async {
    final harness = TranscriptHarness();
    await harness.emit(
      kind: SttTranscriptKind.finalResult,
      segmentId: 'segment-a',
      text: 'Mot.',
    );
    await harness.emit(
      kind: SttTranscriptKind.finalResult,
      segmentId: 'segment-b',
      text: 'Hai.',
    );
    await harness.emit(
      kind: SttTranscriptKind.interim,
      segmentId: 'segment-c',
      text: 'Ba',
    );

    await harness.emit(
      kind: SttTranscriptKind.finalResult,
      segmentId: 'segment-c',
      text: 'Ba.',
    );

    expect(harness.controller.transcript, 'Mot.\nHai.\nBa.');
    await harness.dispose();
  });

  test(
    'final transcript excludes interim segments and preserves order',
    () async {
      final harness = TranscriptHarness();
      await harness.emit(
        kind: SttTranscriptKind.finalResult,
        segmentId: 'segment-a',
        text: 'Xin chào hôm nay.',
      );
      await harness.emit(
        kind: SttTranscriptKind.interim,
        segmentId: 'segment-b',
        text: 'câu đang nói',
      );
      await harness.emit(
        kind: SttTranscriptKind.finalResult,
        segmentId: 'segment-c',
        text: 'Câu đã chốt.',
      );

      expect(
        harness.controller.transcript,
        'Xin chào hôm nay.\ncâu đang nói\nCâu đã chốt.',
      );
      expect(
        harness.controller.finalTranscript,
        'Xin chào hôm nay.\nCâu đã chốt.',
      );
      await harness.dispose();
    },
  );

  test('segment trace records decisions and ordered final snapshots', () async {
    final sink = CapturingControllerTranscriptTraceSink();
    final harness = TranscriptHarness(
      transcriptTrace: createSttTranscriptTrace(enabled: true, sink: sink),
    );
    await harness.emit(
      kind: SttTranscriptKind.interim,
      segmentId: 'segment-a',
      text: 'Mot',
    );
    await harness.emit(
      kind: SttTranscriptKind.interim,
      segmentId: 'segment-a',
      text: 'Mot sua',
    );
    await harness.emit(
      kind: SttTranscriptKind.finalResult,
      segmentId: 'segment-a',
      text: 'Mot.',
    );
    await harness.emit(
      kind: SttTranscriptKind.finalResult,
      segmentId: 'segment-b',
      text: 'Hai.',
    );
    await harness.emit(
      kind: SttTranscriptKind.interim,
      segmentId: 'segment-a',
      text: '',
    );

    final events = sink.lines
        .map(
          (line) =>
              jsonDecode(line.substring(sttTranscriptTraceLinePrefix.length))
                  as Map<String, Object?>,
        )
        .toList();
    final applied = events
        .where((event) => event['event'] == 'segment_applied')
        .toList();
    expect(applied.map((event) => event['action']), [
      'inserted',
      'revised',
      'finalized',
      'inserted',
      'ignored',
    ]);
    expect(applied.last, containsPair('previous_text', 'Mot.'));
    expect(applied.last, containsPair('resulting_text', 'Mot.'));

    final snapshots = events
        .where((event) => event['event'] == 'final_segment_snapshot')
        .toList();
    expect(snapshots, hasLength(2));
    expect(snapshots.last['segments'], [
      {'segment_id': 'segment-a', 'text': 'Mot.'},
      {'segment_id': 'segment-b', 'text': 'Hai.'},
    ]);

    await harness.dispose();
  });

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

  test('stop preserves final transcript and removes current interim', () async {
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
    transport.eventController.add(
      const SttTranscriptEvent(
        kind: SttTranscriptKind.interim,
        segmentId: 'segment-2',
        text: 'unfinished words',
        language: 'vi',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.transcript, 'Previous session\nunfinished words');

    await controller.stop();

    expect(controller.transcript, 'Previous session');
    controller.dispose();
    await transport.eventController.close();
  });

  test('starting a new session resets the previous transcript', () async {
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
    await controller.stop();
    expect(controller.transcript, 'Previous session');

    await controller.start();

    expect(controller.transcript, isEmpty);
    await controller.stop();
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

  test('waits for transport readiness before starting microphone', () async {
    final connectReady = Completer<void>();
    final transport = FakeSttSessionTransport()..pendingConnect = connectReady;
    final microphone = FakeMobileMicrophoneCapture();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      microphoneCapture: microphone,
    );

    final startFuture = controller.start();
    await Future<void>.delayed(Duration.zero);

    expect(microphone.startCalls, 0);
    connectReady.complete();
    await startFuture;
    expect(microphone.startCalls, 1);

    controller.dispose();
    await transport.eventController.close();
    await microphone.audioController.close();
  });

  test(
    'enters listening and starts timer only after microphone starts',
    () async {
      final clock = FakeSessionClock();
      final ticker = FakeSessionTicker(clock);
      final microphone = FakeMobileMicrophoneCapture()
        ..pendingStart = Completer<Stream<Uint8List>>();
      final transport = FakeSttSessionTransport();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        microphoneCapture: microphone,
        clock: clock,
        ticker: ticker,
      );

      final startFuture = controller.start();
      await Future<void>.delayed(Duration.zero);
      ticker.advance(const Duration(seconds: 2));

      expect(controller.state, LiveSessionState.connecting);
      expect(controller.elapsed, Duration.zero);
      expect(microphone.startCalls, 1);

      microphone.pendingStart!.complete(microphone.audioController.stream);
      await startFuture;
      ticker.advance(const Duration(seconds: 3));

      expect(controller.state, LiveSessionState.listening);
      expect(controller.elapsed, const Duration(seconds: 3));
      expect(microphone.startCalls, 1);
      expect(microphone.listenCalls, 1);

      controller.dispose();
      await transport.eventController.close();
      await microphone.audioController.close();
    },
  );

  test('forwards each listening audio chunk unchanged', () async {
    final microphone = FakeMobileMicrophoneCapture();
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      microphoneCapture: microphone,
    );
    await controller.start();
    final first = Uint8List.fromList([0, 1, 2]);
    final second = Uint8List.fromList([3, 4]);

    microphone.audioController.add(first);
    microphone.audioController.add(second);
    await Future<void>.delayed(Duration.zero);

    expect(transport.sentAudio, hasLength(2));
    expect(identical(transport.sentAudio[0], first), isTrue);
    expect(identical(transport.sentAudio[1], second), isTrue);

    controller.dispose();
    await transport.eventController.close();
    await microphone.audioController.close();
  });

  test('serializes audio sends without reordering chunks', () async {
    final firstSend = Completer<void>();
    final secondSend = Completer<void>();
    final microphone = FakeMobileMicrophoneCapture();
    final transport = FakeSttSessionTransport()
      ..sendAudioGates.addAll([firstSend, secondSend]);
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      microphoneCapture: microphone,
    );
    await controller.start();
    final first = Uint8List.fromList([1]);
    final second = Uint8List.fromList([2]);

    microphone.audioController.add(first);
    microphone.audioController.add(second);

    expect(transport.sentAudio, <Matcher>[same(first)]);
    expect(transport.maxActiveAudioSends, 1);

    firstSend.complete();
    await Future<void>.delayed(Duration.zero);
    expect(transport.sentAudio, <Matcher>[same(first), same(second)]);
    expect(transport.maxActiveAudioSends, 1);

    secondSend.complete();
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    await transport.eventController.close();
    await microphone.audioController.close();
  });

  test('stop waits for the in-flight audio frame before stt.stop', () async {
    final sendReady = Completer<void>();
    final microphone = FakeMobileMicrophoneCapture();
    final transport = FakeSttSessionTransport()..sendAudioGates.add(sendReady);
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      microphoneCapture: microphone,
    );
    await controller.start();
    microphone.audioController.add(Uint8List.fromList([1]));

    final stopFuture = controller.stop();
    await Future<void>.delayed(Duration.zero);

    expect(transport.stopCalls, 0);
    sendReady.complete();
    await stopFuture;
    expect(transport.stopCalls, 1);

    controller.dispose();
    await transport.eventController.close();
    await microphone.audioController.close();
  });

  test('pause gates audio before microphone pause completes', () async {
    final microphone = FakeMobileMicrophoneCapture()
      ..pendingPause = Completer<void>();
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      microphoneCapture: microphone,
    );
    await controller.start();

    final pauseFuture = controller.pause();
    microphone.audioController.add(Uint8List.fromList([1]));

    expect(controller.state, LiveSessionState.paused);
    expect(transport.sentAudio, isEmpty);
    microphone.pendingPause!.complete();
    await pauseFuture;

    controller.dispose();
    await transport.eventController.close();
    await microphone.audioController.close();
  });

  test(
    'resume releases backpressure from a send completed while paused',
    () async {
      final sendReady = Completer<void>();
      final microphone = FakeMobileMicrophoneCapture();
      final transport = FakeSttSessionTransport()
        ..sendAudioGates.add(sendReady);
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        microphoneCapture: microphone,
      );
      await controller.start();
      microphone.audioController.add(Uint8List.fromList([1]));

      await controller.pause();
      sendReady.complete();
      await Future<void>.delayed(Duration.zero);
      await controller.resume();
      final resumedChunk = Uint8List.fromList([2]);
      microphone.audioController.add(resumedChunk);
      await Future<void>.delayed(Duration.zero);

      expect(transport.sentAudio, hasLength(2));
      expect(identical(transport.sentAudio.last, resumedChunk), isTrue);

      controller.dispose();
      await transport.eventController.close();
      await microphone.audioController.close();
    },
  );

  test(
    'resume reuses the microphone stream and continues forwarding',
    () async {
      final microphone = FakeMobileMicrophoneCapture();
      final transport = FakeSttSessionTransport();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        microphoneCapture: microphone,
      );
      await controller.start();
      await controller.pause();

      await controller.resume();
      final chunk = Uint8List.fromList([7, 8]);
      microphone.audioController.add(chunk);

      expect(controller.state, LiveSessionState.listening);
      expect(microphone.startCalls, 1);
      expect(microphone.listenCalls, 1);
      expect(microphone.resumeCalls, 1);
      expect(transport.sentAudio, <Matcher>[same(chunk)]);

      controller.dispose();
      await transport.eventController.close();
      await microphone.audioController.close();
    },
  );

  test('stop gates all chunks emitted after it is requested', () async {
    final microphone = FakeMobileMicrophoneCapture();
    final transport = FakeSttSessionTransport()
      ..pendingDisconnect = Completer<void>();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      microphoneCapture: microphone,
    );
    await controller.start();

    final stopFuture = controller.stop();
    microphone.audioController.add(Uint8List.fromList([9]));

    expect(transport.sentAudio, isEmpty);
    transport.pendingDisconnect!.complete();
    await stopFuture;

    controller.dispose();
    await transport.eventController.close();
    await microphone.audioController.close();
  });

  test('stop cleanup is ordered and idempotent', () async {
    final operations = <String>[];
    final microphone = FakeMobileMicrophoneCapture(operations: operations);
    final transport = FakeSttSessionTransport(operations: operations);
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      microphoneCapture: microphone,
    );
    await controller.start();
    operations.clear();

    await Future.wait([controller.stop(), controller.stop()]);

    expect(operations, <String>[
      'microphone.cancel',
      'microphone.stop',
      'transport.stop',
      'transport.disconnect',
    ]);
    expect(controller.state, LiveSessionState.ready);

    controller.dispose();
    await transport.eventController.close();
    await microphone.audioController.close();
  });

  test(
    'microphone start failure cleans up and exposes sanitized error',
    () async {
      final operations = <String>[];
      final microphone = FakeMobileMicrophoneCapture(operations: operations)
        ..startError = Exception('secret recorder path and device details');
      final transport = FakeSttSessionTransport(operations: operations);
      final clock = FakeSessionClock();
      final ticker = FakeSessionTicker(clock);
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        microphoneCapture: microphone,
        clock: clock,
        ticker: ticker,
      );

      await controller.start();
      ticker.advance(const Duration(seconds: 4));

      expect(controller.state, LiveSessionState.error);
      expect(controller.errorMessage, 'Unable to start microphone capture.');
      expect(controller.errorMessage, isNot(contains('secret')));
      expect(controller.canRetry, isTrue);
      expect(controller.elapsed, Duration.zero);
      expect(operations, <String>[
        'microphone.start',
        'microphone.stop',
        'transport.disconnect',
      ]);

      controller.dispose();
      await transport.eventController.close();
      unawaited(microphone.audioController.close());
    },
  );

  test(
    'microphone stream error enters recoverable Error and cleans up',
    () async {
      final microphone = FakeMobileMicrophoneCapture();
      final transport = FakeSttSessionTransport();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        microphoneCapture: microphone,
      );
      await controller.start();

      microphone.audioController.addError(
        Exception('private recorder device path'),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, LiveSessionState.error);
      expect(
        controller.errorMessage,
        'Microphone capture stopped unexpectedly.',
      );
      expect(controller.errorMessage, isNot(contains('private')));
      expect(controller.canRetry, isTrue);
      expect(microphone.stopCalls, 1);
      expect(transport.disconnectCalls, 1);

      controller.dispose();
      await transport.eventController.close();
      await microphone.audioController.close();
    },
  );

  test(
    'unexpected microphone stream completion cleans up the session',
    () async {
      final microphone = FakeMobileMicrophoneCapture();
      final transport = FakeSttSessionTransport();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        microphoneCapture: microphone,
      );
      await controller.start();

      await microphone.audioController.close();
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, LiveSessionState.error);
      expect(
        controller.errorMessage,
        'Microphone capture stopped unexpectedly.',
      );
      expect(controller.canRetry, isTrue);
      expect(microphone.stopCalls, 1);
      expect(transport.disconnectCalls, 1);

      controller.dispose();
      await transport.eventController.close();
    },
  );

  test(
    'unexpected disconnect pauses and gates audio while reconnecting',
    () async {
      final reconnectReady = Completer<void>();
      final microphone = FakeMobileMicrophoneCapture();
      final transport = FakeSttSessionTransport()
        ..connectResults.addAll([Future<void>.value(), reconnectReady.future]);
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        microphoneCapture: microphone,
      );
      await controller.start();

      transport.eventController.add(
        const SttSessionClosedEvent(unexpected: true),
      );
      await Future<void>.delayed(Duration.zero);
      microphone.audioController.add(Uint8List.fromList([10]));

      expect(controller.state, LiveSessionState.reconnecting);
      expect(microphone.pauseCalls, 1);
      expect(transport.sentAudio, isEmpty);

      await controller.stop();
      reconnectReady.complete();
      controller.dispose();
      await transport.eventController.close();
      await microphone.audioController.close();
    },
  );

  test('successful reconnect resumes capture and audio forwarding', () async {
    final reconnectReady = Completer<void>();
    final microphone = FakeMobileMicrophoneCapture();
    final transport = FakeSttSessionTransport()
      ..connectResults.addAll([Future<void>.value(), reconnectReady.future]);
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      microphoneCapture: microphone,
    );
    await controller.start();
    transport.eventController.add(
      const SttSessionClosedEvent(unexpected: true),
    );
    await Future<void>.delayed(Duration.zero);

    reconnectReady.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final chunk = Uint8List.fromList([11]);
    microphone.audioController.add(chunk);

    expect(controller.state, LiveSessionState.listening);
    expect(microphone.resumeCalls, 1);
    expect(microphone.startCalls, 1);
    expect(microphone.listenCalls, 1);
    expect(transport.sentAudio, <Matcher>[same(chunk)]);

    controller.dispose();
    await transport.eventController.close();
    await microphone.audioController.close();
  });

  test('reconnect waits for stale send before resuming subscription', () async {
    final staleSend = Completer<void>();
    final microphone = FakeMobileMicrophoneCapture();
    final transport = FakeSttSessionTransport()..sendAudioGates.add(staleSend);
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      microphoneCapture: microphone,
    );
    await controller.start();
    microphone.audioController.add(Uint8List.fromList([1]));

    transport.eventController.add(
      const SttSessionClosedEvent(unexpected: true),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, LiveSessionState.reconnecting);
    expect(transport.sentAudio, hasLength(1));
    expect(transport.maxActiveAudioSends, 1);

    staleSend.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final reconnectedChunk = Uint8List.fromList([2]);
    microphone.audioController.add(reconnectedChunk);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, LiveSessionState.listening);
    expect(transport.sentAudio, hasLength(2));
    expect(identical(transport.sentAudio.last, reconnectedChunk), isTrue);
    expect(transport.maxActiveAudioSends, 1);
    expect(microphone.startCalls, 1);
    expect(microphone.listenCalls, 1);

    controller.dispose();
    await transport.eventController.close();
    await microphone.audioController.close();
  });

  test(
    'reconnect discards audio buffered behind an in-flight stale send',
    () async {
      final staleSend = Completer<void>();
      final reconnectReady = Completer<void>();
      final microphone = FakeMobileMicrophoneCapture();
      final transport = FakeSttSessionTransport()
        ..sendAudioGates.add(staleSend)
        ..connectResults.addAll([Future<void>.value(), reconnectReady.future]);
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        microphoneCapture: microphone,
      );
      await controller.start();
      final first = Uint8List.fromList([1]);
      final bufferedBeforeReconnect = Uint8List.fromList([2]);
      microphone.audioController.add(first);
      microphone.audioController.add(bufferedBeforeReconnect);

      transport.eventController.add(
        const SttSessionClosedEvent(unexpected: true),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.state, LiveSessionState.reconnecting);
      expect(transport.sentAudio, <Matcher>[same(first)]);

      staleSend.complete();
      await Future<void>.delayed(Duration.zero);
      reconnectReady.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, LiveSessionState.listening);
      expect(transport.sentAudio, <Matcher>[same(first)]);

      controller.dispose();
      await transport.eventController.close();
      await microphone.audioController.close();
    },
  );

  test('reconnect from paused stays paused without forwarding', () async {
    final microphone = FakeMobileMicrophoneCapture();
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      microphoneCapture: microphone,
    );
    await controller.start();
    await controller.pause();

    transport.eventController.add(
      const SttSessionClosedEvent(unexpected: true),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    microphone.audioController.add(Uint8List.fromList([12]));

    expect(controller.state, LiveSessionState.paused);
    expect(microphone.resumeCalls, 0);
    expect(transport.sentAudio, isEmpty);

    controller.dispose();
    await transport.eventController.close();
    await microphone.audioController.close();
  });

  test('repeated reconnects keep one microphone start and listener', () async {
    final microphone = FakeMobileMicrophoneCapture();
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      microphoneCapture: microphone,
    );
    await controller.start();

    for (var reconnect = 0; reconnect < 2; reconnect++) {
      transport.eventController.add(
        const SttSessionClosedEvent(unexpected: true),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    }

    expect(controller.state, LiveSessionState.listening);
    expect(microphone.startCalls, 1);
    expect(microphone.listenCalls, 1);
    expect(microphone.resumeCalls, 2);

    controller.dispose();
    await transport.eventController.close();
    await microphone.audioController.close();
  });

  test(
    'dispose cancels audio, disposes microphone, and ignores late work',
    () async {
      final operations = <String>[];
      final microphone = FakeMobileMicrophoneCapture(operations: operations);
      final transport = FakeSttSessionTransport(operations: operations);
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        microphoneCapture: microphone,
      );
      await controller.start();
      var notifications = 0;
      controller.addListener(() => notifications++);
      operations.clear();

      controller.dispose();
      microphone.audioController.add(Uint8List.fromList([13]));
      transport.eventController.add(
        const SttTranscriptEvent(
          kind: SttTranscriptKind.finalResult,
          segmentId: 'late',
          text: 'late transcript',
          language: 'en',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(notifications, 0);
      expect(transport.sentAudio, isEmpty);
      expect(operations, <String>[
        'microphone.cancel',
        'microphone.dispose',
        'transport.disconnect',
      ]);

      await transport.eventController.close();
      await microphone.audioController.close();
    },
  );

  test(
    'audio send failure is contained and later chunks still forward',
    () async {
      final microphone = FakeMobileMicrophoneCapture();
      final transport = FakeSttSessionTransport()
        ..sendAudioError = Exception('socket send failed');
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        microphoneCapture: microphone,
      );
      await controller.start();

      microphone.audioController.add(Uint8List.fromList([1]));
      await Future<void>.delayed(Duration.zero);
      transport.sendAudioError = null;
      microphone.audioController.add(Uint8List.fromList([2]));
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, LiveSessionState.listening);
      expect(transport.sentAudio, hasLength(2));

      controller.dispose();
      await transport.eventController.close();
      await microphone.audioController.close();
    },
  );

  test(
    'defaults to microphone and exposes system audio availability',
    () async {
      final transport = FakeSttSessionTransport();
      final systemAudio = FakeMobileMicrophoneCapture();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        systemAudioInput: systemAudio,
        systemAudioSupportQuery: () async => true,
      );

      await controller.audioSourceSupportReady;

      expect(controller.selectedAudioSource, MobileAudioSource.microphone);
      expect(controller.isSystemAudioSupported, isTrue);

      controller.dispose();
      await transport.eventController.close();
      unawaited(systemAudio.audioController.close());
    },
  );

  test('unsupported system audio cannot be selected', () async {
    final transport = FakeSttSessionTransport();
    final systemAudio = FakeMobileMicrophoneCapture();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      systemAudioInput: systemAudio,
      systemAudioSupportQuery: () async => false,
    );

    await controller.audioSourceSupportReady;

    expect(
      controller.selectAudioSource(MobileAudioSource.systemAudio),
      isFalse,
    );
    expect(controller.selectedAudioSource, MobileAudioSource.microphone);

    controller.dispose();
    await transport.eventController.close();
    unawaited(systemAudio.audioController.close());
  });

  test(
    'system audio becomes ready before the STT transport connects',
    () async {
      final captureReady = Completer<Stream<Uint8List>>();
      final microphone = FakeMobileMicrophoneCapture();
      final systemAudio = FakeMobileMicrophoneCapture()
        ..pendingStart = captureReady;
      final transport = FakeSttSessionTransport();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        microphoneCapture: microphone,
        systemAudioInput: systemAudio,
        systemAudioSupportQuery: () async => true,
      );
      await controller.audioSourceSupportReady;
      controller.selectAudioSource(MobileAudioSource.systemAudio);

      final start = controller.start();
      await Future<void>.delayed(Duration.zero);

      expect(systemAudio.startCalls, 1);
      expect(transport.connectCalls, 0);

      captureReady.complete(systemAudio.audioController.stream);
      await start;

      expect(transport.connectCalls, 1);
      expect(controller.state, LiveSessionState.listening);

      await controller.stop();
      controller.dispose();
      await transport.eventController.close();
      unawaited(microphone.audioController.close());
      await systemAudio.audioController.close();
    },
  );

  test(
    'system permission cancellation never opens the STT transport',
    () async {
      final microphone = FakeMobileMicrophoneCapture();
      final systemAudio = FakeMobileMicrophoneCapture()
        ..startError = const AudioInputException(
          code: 'projection_cancelled',
          message: 'System Audio permission was cancelled.',
        );
      final transport = FakeSttSessionTransport();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        microphoneCapture: microphone,
        systemAudioInput: systemAudio,
        systemAudioSupportQuery: () async => true,
      );
      await controller.audioSourceSupportReady;
      controller.selectAudioSource(MobileAudioSource.systemAudio);

      await controller.start();

      expect(controller.state, LiveSessionState.error);
      expect(controller.errorMessage, 'System Audio permission was cancelled.');
      expect(transport.connectCalls, 0);

      await controller.stop();
      controller.dispose();
      await transport.eventController.close();
      unawaited(microphone.audioController.close());
      unawaited(systemAudio.audioController.close());
    },
  );

  test('system audio can retry after a controlled start failure', () async {
    final microphone = FakeMobileMicrophoneCapture();
    final systemAudio = FakeMobileMicrophoneCapture()
      ..startError = const AudioInputException(
        code: 'projection_cancelled',
        message: 'System Audio permission was cancelled.',
      );
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      microphoneCapture: microphone,
      systemAudioInput: systemAudio,
      systemAudioSupportQuery: () async => true,
    );
    await controller.audioSourceSupportReady;
    controller.selectAudioSource(MobileAudioSource.systemAudio);

    await controller.start();
    expect(controller.state, LiveSessionState.error);
    expect(transport.connectCalls, 0);

    systemAudio.startError = null;
    await controller.retry();

    expect(controller.state, LiveSessionState.listening);
    expect(systemAudio.startCalls, 2);
    expect(transport.connectCalls, 1);
    expect(controller.selectedAudioSource, MobileAudioSource.systemAudio);

    await controller.stop();
    controller.dispose();
    await transport.eventController.close();
    unawaited(microphone.audioController.close());
    await systemAudio.audioController.close();
  });

  test('source is locked while active and retained after Stop', () async {
    final microphone = FakeMobileMicrophoneCapture();
    final systemAudio = FakeMobileMicrophoneCapture();
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      microphoneCapture: microphone,
      systemAudioInput: systemAudio,
      systemAudioSupportQuery: () async => true,
    );
    await controller.audioSourceSupportReady;
    controller.selectAudioSource(MobileAudioSource.systemAudio);
    await controller.start();

    expect(controller.selectAudioSource(MobileAudioSource.microphone), isFalse);
    expect(controller.selectedAudioSource, MobileAudioSource.systemAudio);

    await controller.stop();

    expect(controller.state, LiveSessionState.ready);
    expect(controller.selectedAudioSource, MobileAudioSource.systemAudio);
    expect(systemAudio.stopCalls, 1);
    expect(microphone.stopCalls, 0);

    controller.dispose();
    await transport.eventController.close();
    unawaited(microphone.audioController.close());
    await systemAudio.audioController.close();
  });

  test(
    'system audio uses the same transport and Pause Resume semantics',
    () async {
      final microphone = FakeMobileMicrophoneCapture();
      final systemAudio = FakeMobileMicrophoneCapture();
      final transport = FakeSttSessionTransport();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        microphoneCapture: microphone,
        systemAudioInput: systemAudio,
        systemAudioSupportQuery: () async => true,
      );
      await controller.audioSourceSupportReady;
      controller.selectAudioSource(MobileAudioSource.systemAudio);
      await controller.start();
      final first = Uint8List.fromList([1, 0]);
      systemAudio.audioController.add(first);
      await Future<void>.delayed(Duration.zero);

      await controller.pause();
      systemAudio.audioController.add(Uint8List.fromList([2, 0]));
      await controller.resume();
      final resumed = Uint8List.fromList([3, 0]);
      systemAudio.audioController.add(resumed);
      await Future<void>.delayed(Duration.zero);

      expect(transport.sentAudio, <Matcher>[same(first), same(resumed)]);
      expect(systemAudio.pauseCalls, 1);
      expect(systemAudio.resumeCalls, 1);
      expect(microphone.startCalls, 0);

      await controller.stop();
      controller.dispose();
      await transport.eventController.close();
      unawaited(microphone.audioController.close());
      await systemAudio.audioController.close();
    },
  );

  test('native system capture ending reaches controlled retry state', () async {
    final microphone = FakeMobileMicrophoneCapture();
    final systemAudio = FakeMobileMicrophoneCapture();
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      microphoneCapture: microphone,
      systemAudioInput: systemAudio,
      systemAudioSupportQuery: () async => true,
    );
    await controller.audioSourceSupportReady;
    controller.selectAudioSource(MobileAudioSource.systemAudio);
    await controller.start();

    await systemAudio.audioController.close();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, LiveSessionState.error);
    expect(
      controller.errorMessage,
      'System Audio capture stopped unexpectedly.',
    );
    expect(controller.canRetry, isTrue);
    expect(transport.disconnectCalls, 1);

    controller.dispose();
    await transport.eventController.close();
    unawaited(microphone.audioController.close());
  });

  test(
    'native system capture ending while paused still cleans the session',
    () async {
      final microphone = FakeMobileMicrophoneCapture();
      final systemAudio = FakeMobileMicrophoneCapture();
      final transport = FakeSttSessionTransport();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
        microphoneCapture: microphone,
        systemAudioInput: systemAudio,
        systemAudioSupportQuery: () async => true,
      );
      await controller.audioSourceSupportReady;
      controller.selectAudioSource(MobileAudioSource.systemAudio);
      await controller.start();
      await controller.pause();

      await systemAudio.audioController.close();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, LiveSessionState.error);
      expect(
        controller.errorMessage,
        'System Audio capture stopped unexpectedly.',
      );
      expect(transport.disconnectCalls, 1);

      controller.dispose();
      await transport.eventController.close();
      unawaited(microphone.audioController.close());
    },
  );

  test(
    'default Translation target is English and locks for active session',
    () async {
      final transport = FakeSttSessionTransport();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
      );

      expect(controller.selectedTranslationTarget, defaultTranslationTarget);
      expect(
        controller.selectTranslationTarget(TranslationTargetLanguage.japanese),
        isTrue,
      );
      await controller.start();

      expect(
        transport.connectOptions.single.translationTarget,
        TranslationTargetLanguage.japanese,
      );
      expect(
        controller.selectTranslationTarget(TranslationTargetLanguage.french),
        isFalse,
      );
      await controller.pause();
      expect(
        controller.selectTranslationTarget(TranslationTargetLanguage.french),
        isFalse,
      );
      await controller.stop();
      expect(
        controller.selectTranslationTarget(TranslationTargetLanguage.french),
        isTrue,
      );

      controller.dispose();
      await transport.eventController.close();
    },
  );

  test('STT-only mode omits Translation start configuration', () async {
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
      translationEnabled: false,
    );

    await controller.start();

    expect(transport.connectOptions.single.translationTarget, isNull);
    expect(controller.usesBilingualPresentation, isFalse);

    await controller.stop();
    controller.dispose();
    await transport.eventController.close();
  });

  test(
    'Translation events update typed state without changing STT state',
    () async {
      final transport = FakeSttSessionTransport();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
      );
      await controller.start();

      transport.eventController.add(
        const SttTranslationEvent(
          TranslationConfiguredEvent(
            streamId: 'stream_A',
            sourceLanguage: 'vi',
            targetLanguage: TranslationTargetLanguage.korean,
          ),
        ),
      );
      transport.eventController.add(
        const SttTranslationEvent(
          TranslationPendingEvent(
            streamId: 'stream_A',
            utteranceId: 'utt_000001',
            sourceSegmentIds: ['seg_1'],
            sourceText: 'Nguon chuan.',
            sourceLanguage: 'vi',
            targetLanguage: TranslationTargetLanguage.korean,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, LiveSessionState.listening);
      expect(
        controller.selectedTranslationTarget,
        TranslationTargetLanguage.korean,
      );
      expect(
        controller.translationState.utterances.single.status,
        TranslationStatus.pending,
      );

      transport.eventController.add(
        const SttTranslationEvent(
          TranslationFinalEvent(
            streamId: 'stream_A',
            utteranceId: 'utt_000001',
            sourceSegmentIds: ['seg_1'],
            sourceText: 'Nguon chuan.',
            sourceLanguage: 'vi',
            targetLanguage: TranslationTargetLanguage.korean,
            translatedText: 'Translated.',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.translationState.utterances, hasLength(1));
      expect(
        controller.translationState.utterances.single.status,
        TranslationStatus.finalResult,
      );

      await controller.stop();
      controller.dispose();
      await transport.eventController.close();
    },
  );

  test('source ownership is stream-aware and keeps interim visible', () async {
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
    );
    await controller.start();
    transport.eventController.add(
      const SttTranscriptEvent(
        kind: SttTranscriptKind.finalResult,
        streamId: 'stream_A',
        segmentId: 'seg_1',
        text: 'Visible immediately.',
        language: 'vi',
      ),
    );
    transport.eventController.add(
      const SttTranscriptEvent(
        kind: SttTranscriptKind.finalResult,
        streamId: 'stream_B',
        segmentId: 'seg_1',
        text: 'Other stream.',
        language: 'vi',
      ),
    );
    transport.eventController.add(
      const SttTranscriptEvent(
        kind: SttTranscriptKind.interim,
        streamId: 'stream_A',
        segmentId: 'seg_live',
        text: 'Still speaking',
        language: 'vi',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.translationPresentation.liveSpeechSegments, hasLength(3));

    transport.eventController.add(
      const SttTranslationEvent(
        TranslationPendingEvent(
          streamId: 'stream_A',
          utteranceId: 'utt_000001',
          sourceSegmentIds: ['seg_1'],
          sourceText: 'Backend canonical grouping.',
          sourceLanguage: 'vi',
          targetLanguage: TranslationTargetLanguage.english,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      controller.translationPresentation.liveSpeechSegments.map(
        (segment) => (segment.streamId, segment.segmentId),
      ),
      [('stream_B', 'seg_1'), ('stream_A', 'seg_live')],
    );
    expect(
      controller.translationPresentation.utterances.single.sourceText,
      'Backend canonical grouping.',
    );

    await controller.stop();
    controller.dispose();
    await transport.eventController.close();
  });

  test(
    'session Translation failure leaves STT live and is deduplicated',
    () async {
      final transport = FakeSttSessionTransport();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
      );
      await controller.start();
      const event = SttTranslationEvent(
        TranslationSessionErrorEvent(
          streamId: 'stream_A',
          sourceLanguage: 'vi',
          targetLanguage: TranslationTargetLanguage.english,
          code: 'provider_unavailable',
          message: 'Unavailable.',
        ),
      );
      transport.eventController.add(event);
      transport.eventController.add(event);
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, LiveSessionState.listening);
      expect(controller.translationState.sessionErrors, hasLength(1));
      expect(
        controller.translationWarning,
        'Translation is unavailable. Original transcript will continue.',
      );

      await controller.stop();
      controller.dispose();
      await transport.eventController.close();
    },
  );

  test('healthy configured stream clears a prior stream warning', () async {
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
    );
    await controller.start();
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
    await Future<void>.delayed(Duration.zero);
    expect(controller.translationWarning, isNotNull);

    transport.eventController.add(
      const SttTranslationEvent(
        TranslationConfiguredEvent(
          streamId: 'stream_B',
          sourceLanguage: 'vi',
          targetLanguage: TranslationTargetLanguage.japanese,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.translationWarning, isNull);
    expect(
      controller.selectedTranslationTarget,
      TranslationTargetLanguage.japanese,
    );

    await controller.stop();
    controller.dispose();
    await transport.eventController.close();
  });

  test('unexpected reconnect deactivates the prior stream warning', () async {
    final reconnectReady = Completer<void>();
    final transport = FakeSttSessionTransport()
      ..connectResults.addAll([Future<void>.value(), reconnectReady.future]);
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
    );
    await controller.start();
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
    await Future<void>.delayed(Duration.zero);
    expect(controller.translationWarning, isNotNull);

    transport.eventController.add(
      const SttSessionClosedEvent(unexpected: true),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, LiveSessionState.reconnecting);
    expect(controller.translationWarning, isNull);

    reconnectReady.complete();
    await Future<void>.delayed(Duration.zero);
    await controller.stop();
    controller.dispose();
    await transport.eventController.close();
  });

  test('active-session retry deactivates the prior stream warning', () async {
    final reconnectReady = Completer<void>();
    final transport = FakeSttSessionTransport()
      ..connectResults.addAll([Future<void>.value(), reconnectReady.future]);
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
    );
    await controller.start();
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
    transport.eventController.add(
      const SttSessionErrorEvent(
        code: 'provider_error',
        message: 'Reconnect.',
        recoverable: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.translationWarning, isNotNull);

    final retry = controller.retry();
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, LiveSessionState.reconnecting);
    expect(controller.translationWarning, isNull);

    reconnectReady.complete();
    await retry;
    await controller.stop();
    controller.dispose();
    await transport.eventController.close();
  });

  test('clean Stop deactivates the completed stream warning', () async {
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
    );
    await controller.start();
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
    await Future<void>.delayed(Duration.zero);
    expect(controller.translationWarning, isNotNull);

    await controller.stop();

    expect(controller.state, LiveSessionState.ready);
    expect(controller.translationWarning, isNull);

    controller.dispose();
    await transport.eventController.close();
  });

  test('queue overflow fails only its utterance and STT continues', () async {
    final transport = FakeSttSessionTransport();
    final controller = LiveSessionController(
      permissionGateway: FakeMicrophonePermissionGateway(),
      transport: transport,
    );
    await controller.start();
    transport.eventController.add(
      const SttTranslationEvent(
        TranslationUtteranceErrorEvent(
          streamId: 'stream_A',
          utteranceId: 'utt_000001',
          sourceSegmentIds: ['seg_1'],
          sourceText: 'Original.',
          sourceLanguage: 'vi',
          targetLanguage: TranslationTargetLanguage.english,
          code: 'queue_overflow',
          message: 'Busy.',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, LiveSessionState.listening);
    expect(controller.errorMessage, isNull);
    expect(
      controller.translationState.utterances.single.status,
      TranslationStatus.failed,
    );

    await controller.stop();
    controller.dispose();
    await transport.eventController.close();
  });

  test(
    'Stop retains trailing source and Translation until transport drain ends',
    () async {
      final transport = FakeSttSessionTransport()
        ..pendingStop = Completer<void>();
      final controller = LiveSessionController(
        permissionGateway: FakeMicrophonePermissionGateway(),
        transport: transport,
      );
      await controller.start();

      final stopFuture = controller.stop();
      while (transport.stopCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(transport.disconnectCalls, 0);
      transport.eventController.add(
        const SttTranscriptEvent(
          kind: SttTranscriptKind.finalResult,
          streamId: 'stream_A',
          segmentId: 'seg_tail',
          text: 'Tail.',
          language: 'vi',
        ),
      );
      transport.eventController.add(
        const SttTranslationEvent(
          TranslationFinalEvent(
            streamId: 'stream_A',
            utteranceId: 'utt_tail',
            sourceSegmentIds: ['seg_tail'],
            sourceText: 'Tail.',
            sourceLanguage: 'vi',
            targetLanguage: TranslationTargetLanguage.english,
            translatedText: 'Tail translated.',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        controller.translationState.utterances.single.translatedText,
        'Tail translated.',
      );

      transport.pendingStop!.complete();
      await stopFuture;
      expect(
        transport.operations.indexOf('transport.stop'),
        lessThan(transport.operations.indexOf('transport.disconnect')),
      );
      expect(controller.finalTranscript, 'Tail.');

      controller.dispose();
      await transport.eventController.close();
    },
  );
}

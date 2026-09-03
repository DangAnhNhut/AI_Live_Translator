import 'dart:async';
import 'dart:typed_data';

import 'package:ai_live_translator_mobile/services/audio_input.dart';
import 'package:ai_live_translator_mobile/services/microphone_capture_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

void main() {
  test(
    'record microphone capture implements the shared audio input contract',
    () async {
      final capture = RecordMicrophoneCapture(
        recorder: _FakeAudioRecorderDriver(Stream<Uint8List>.empty()),
      );

      expect(capture, isA<MobileAudioInput>());

      await capture.dispose();
    },
  );

  test(
    'start exposes the recorder raw stream with 16 kHz mono PCM16',
    () async {
      final audioStream = Stream<Uint8List>.empty();
      final recorder = _FakeAudioRecorderDriver(audioStream);
      final capture = RecordMicrophoneCapture(recorder: recorder);

      final stream = await capture.start();

      expect(stream, same(audioStream));
      expect(recorder.startConfigs, hasLength(1));
      final config = recorder.startConfigs.single;
      expect(config.encoder, AudioEncoder.pcm16bits);
      expect(config.sampleRate, 16000);
      expect(config.numChannels, 1);

      await capture.dispose();
      expect(recorder.stopCalls, 1);
      expect(recorder.disposeCalls, 1);
    },
  );

  test(
    'lifecycle operations are delegated at most once per active state',
    () async {
      final recorder = _FakeAudioRecorderDriver(Stream<Uint8List>.empty());
      final capture = RecordMicrophoneCapture(recorder: recorder);

      await capture.start();
      await capture.pause();
      await capture.pause();
      await capture.resume();
      await capture.resume();
      await capture.stop();
      await capture.stop();
      await capture.dispose();
      await capture.dispose();

      expect(recorder.startConfigs, hasLength(1));
      expect(recorder.pauseCalls, 1);
      expect(recorder.resumeCalls, 1);
      expect(recorder.stopCalls, 1);
      expect(recorder.disposeCalls, 1);
    },
  );

  test('start after stop begins a new recorder stream', () async {
    final recorder = _FakeAudioRecorderDriver(Stream<Uint8List>.empty());
    final capture = RecordMicrophoneCapture(recorder: recorder);

    await capture.start();
    await capture.stop();
    await capture.start();

    expect(recorder.startConfigs, hasLength(2));
    await capture.dispose();
    expect(recorder.stopCalls, 2);
  });

  test('concurrent starts share one driver start and raw stream', () async {
    final recorder = _DeferredAudioRecorderDriver();
    final capture = RecordMicrophoneCapture(recorder: recorder);

    final firstStart = capture.start();
    final secondStart = capture.start();

    await recorder.startCalled.future;
    expect(recorder.calls, ['start']);
    recorder.completeStart();

    final streams = await Future.wait([firstStart, secondStart]);
    expect(streams.first, same(recorder.audioStream));
    expect(streams.last, same(recorder.audioStream));
    expect(recorder.calls, ['start']);
    final dispose = capture.dispose();
    await recorder.stopCalled.future;
    recorder.completeStop();
    await recorder.disposeCalled.future;
    recorder.completeDispose();
    await dispose;
  });

  test('stop queued during start stops the newly active capture', () async {
    final recorder = _DeferredAudioRecorderDriver();
    final capture = RecordMicrophoneCapture(recorder: recorder);

    final starting = capture.start();
    final stopping = capture.stop();
    await recorder.startCalled.future;
    expect(recorder.calls, ['start']);

    recorder.completeStart();
    await recorder.stopCalled.future;
    expect(recorder.calls, ['start', 'stop']);
    recorder.completeStop();
    await Future.wait([starting, stopping]);

    final restarting = capture.start();
    await restarting;
    expect(recorder.calls, ['start', 'stop', 'start']);
    final dispose = capture.dispose();
    await recorder.disposeCalled.future;
    recorder.completeDispose();
    await dispose;
  });

  test(
    'dispose queued during start stops and disposes before rejecting restart',
    () async {
      final recorder = _DeferredAudioRecorderDriver();
      final capture = RecordMicrophoneCapture(recorder: recorder);

      final starting = capture.start();
      final disposing = capture.dispose();
      await recorder.startCalled.future;
      expect(recorder.calls, ['start']);

      recorder.completeStart();
      await recorder.stopCalled.future;
      recorder.completeStop();
      await recorder.disposeCalled.future;
      recorder.completeDispose();
      await Future.wait([starting, disposing]);

      expect(recorder.calls, ['start', 'stop', 'dispose']);
      await expectLater(capture.start(), throwsStateError);
    },
  );

  test(
    'concurrent pause resume and stop use one ordered driver sequence',
    () async {
      final recorder = _DeferredAudioRecorderDriver();
      final capture = RecordMicrophoneCapture(recorder: recorder);

      final starting = capture.start();
      recorder.completeStart();
      await starting;
      recorder.calls.clear();

      final operations = [
        capture.pause(),
        capture.pause(),
        capture.resume(),
        capture.resume(),
        capture.stop(),
        capture.stop(),
      ];
      await recorder.pauseCalled.future;
      expect(recorder.calls, ['pause']);
      recorder.completePause();
      await recorder.resumeCalled.future;
      expect(recorder.calls, ['pause', 'resume']);
      recorder.completeResume();
      await recorder.stopCalled.future;
      expect(recorder.calls, ['pause', 'resume', 'stop']);
      recorder.completeStop();
      await Future.wait(operations);

      expect(recorder.calls, ['pause', 'resume', 'stop']);
      final dispose = capture.dispose();
      await recorder.disposeCalled.future;
      recorder.completeDispose();
      await dispose;
    },
  );

  test('repeated dispose callers await one cleanup completion', () async {
    final recorder = _DeferredAudioRecorderDriver();
    final capture = RecordMicrophoneCapture(recorder: recorder);

    final firstDispose = capture.dispose();
    final secondDispose = capture.dispose();
    var firstComplete = false;
    var secondComplete = false;
    firstDispose.then((_) => firstComplete = true);
    secondDispose.then((_) => secondComplete = true);

    await recorder.disposeCalled.future;
    expect(firstComplete, isFalse);
    expect(secondComplete, isFalse);
    expect(recorder.calls, ['dispose']);
    recorder.completeDispose();
    await Future.wait([firstDispose, secondDispose]);

    expect(firstComplete, isTrue);
    expect(secondComplete, isTrue);
    expect(recorder.calls, ['dispose']);
  });

  test('dispose still releases the recorder after stop fails', () async {
    final stopFailure = StateError('stop failed');
    final recorder = _StopFailingAudioRecorderDriver(stopFailure);
    final capture = RecordMicrophoneCapture(recorder: recorder);

    await capture.start();

    await expectLater(capture.dispose(), throwsA(same(stopFailure)));

    expect(recorder.stopCalls, 1);
    expect(recorder.disposeCalls, 1);
    await capture.pause();
    await capture.resume();
    await capture.stop();
    expect(recorder.pauseCalls, 0);
    expect(recorder.resumeCalls, 0);
    expect(recorder.stopCalls, 1);
    await expectLater(capture.start(), throwsStateError);
  });

  test('debug noop capture stays open silently until disposal', () async {
    final capture = DebugNoopMicrophoneCapture();
    var isDone = false;

    final stream = await capture.start();
    final subscription = stream.listen(
      (_) => fail('debug capture must not emit audio'),
      onDone: () => isDone = true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(isDone, isFalse);
    await capture.pause();
    await capture.resume();
    await capture.stop();
    await capture.stop();
    await capture.dispose();
    await capture.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(isDone, isTrue);
    await subscription.cancel();
  });
}

class _FakeAudioRecorderDriver implements AudioRecorderDriver {
  _FakeAudioRecorderDriver(this.audioStream);

  final Stream<Uint8List> audioStream;
  final List<RecordConfig> startConfigs = [];
  var pauseCalls = 0;
  var resumeCalls = 0;
  var stopCalls = 0;
  var disposeCalls = 0;

  @override
  Future<void> dispose() async {
    disposeCalls++;
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
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    startConfigs.add(config);
    return audioStream;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

class _DeferredAudioRecorderDriver implements AudioRecorderDriver {
  final Stream<Uint8List> audioStream = Stream<Uint8List>.empty();
  final List<String> calls = [];
  final Completer<Stream<Uint8List>> _start = Completer<Stream<Uint8List>>();
  final Completer<void> startCalled = Completer<void>();
  final Completer<void> pauseCalled = Completer<void>();
  final Completer<void> resumeCalled = Completer<void>();
  final Completer<void> stopCalled = Completer<void>();
  final Completer<void> disposeCalled = Completer<void>();
  final Completer<void> _pause = Completer<void>();
  final Completer<void> _resume = Completer<void>();
  final Completer<void> _stop = Completer<void>();
  final Completer<void> _dispose = Completer<void>();

  void completeStart() {
    if (!_start.isCompleted) {
      _start.complete(audioStream);
    }
  }

  void completePause() {
    if (!_pause.isCompleted) {
      _pause.complete();
    }
  }

  void completeResume() {
    if (!_resume.isCompleted) {
      _resume.complete();
    }
  }

  void completeStop() {
    if (!_stop.isCompleted) {
      _stop.complete();
    }
  }

  void completeDispose() {
    if (!_dispose.isCompleted) {
      _dispose.complete();
    }
  }

  @override
  Future<void> dispose() {
    calls.add('dispose');
    if (!disposeCalled.isCompleted) {
      disposeCalled.complete();
    }
    return _dispose.future;
  }

  @override
  Future<void> pause() {
    calls.add('pause');
    if (!pauseCalled.isCompleted) {
      pauseCalled.complete();
    }
    return _pause.future;
  }

  @override
  Future<void> resume() {
    calls.add('resume');
    if (!resumeCalled.isCompleted) {
      resumeCalled.complete();
    }
    return _resume.future;
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) {
    calls.add('start');
    if (!startCalled.isCompleted) {
      startCalled.complete();
    }
    return _start.future;
  }

  @override
  Future<void> stop() {
    calls.add('stop');
    if (!stopCalled.isCompleted) {
      stopCalled.complete();
    }
    return _stop.future;
  }
}

class _StopFailingAudioRecorderDriver implements AudioRecorderDriver {
  _StopFailingAudioRecorderDriver(this.stopFailure);

  final Object stopFailure;
  final Stream<Uint8List> _audioStream = Stream<Uint8List>.empty();
  var pauseCalls = 0;
  var resumeCalls = 0;
  var stopCalls = 0;
  var disposeCalls = 0;

  @override
  Future<void> dispose() async {
    disposeCalls++;
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
  Future<Stream<Uint8List>> startStream(RecordConfig config) async =>
      _audioStream;

  @override
  Future<void> stop() {
    stopCalls++;
    return Future<void>.error(stopFailure);
  }
}

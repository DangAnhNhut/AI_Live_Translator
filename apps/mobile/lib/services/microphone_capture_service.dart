import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'audio_input.dart';

/// Captures raw microphone PCM data for a live session.
abstract interface class MobileMicrophoneCapture implements MobileAudioInput {}

/// Minimal seam around the platform recorder for deterministic unit tests.
abstract interface class AudioRecorderDriver {
  Future<Stream<Uint8List>> startStream(RecordConfig config);

  Future<void> pause();

  Future<void> resume();

  Future<void> stop();

  Future<void> dispose();
}

/// Production microphone capture backed by the `record` package.
class RecordMicrophoneCapture implements MobileMicrophoneCapture {
  RecordMicrophoneCapture({AudioRecorderDriver? recorder})
    : _recorder = recorder ?? _RecordAudioRecorderDriver();

  final AudioRecorderDriver _recorder;

  Stream<Uint8List>? _activeStream;
  bool _isPaused = false;
  bool _isDisposed = false;
  bool _isDisposeRequested = false;
  Future<void> _operationTail = Future<void>.value();
  Future<void>? _disposeFuture;

  @override
  Future<Stream<Uint8List>> start() {
    if (_isDisposeRequested) {
      return Future<Stream<Uint8List>>.error(
        StateError('Microphone capture has been disposed.'),
      );
    }

    return _enqueue(() async {
      _throwIfDisposed();

      final activeStream = _activeStream;
      if (activeStream != null) {
        return activeStream;
      }

      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      _activeStream = stream;
      return stream;
    });
  }

  @override
  Future<void> pause() => _enqueue(() async {
    if (_isDisposed || _activeStream == null || _isPaused) {
      return;
    }

    await _recorder.pause();
    _isPaused = true;
  });

  @override
  Future<void> resume() => _enqueue(() async {
    if (_isDisposed || _activeStream == null || !_isPaused) {
      return;
    }

    await _recorder.resume();
    _isPaused = false;
  });

  @override
  Future<void> stop() => _enqueue(() async {
    if (_isDisposed || _activeStream == null) {
      return;
    }

    await _recorder.stop();
    _activeStream = null;
    _isPaused = false;
  });

  @override
  Future<void> dispose() {
    final existingDispose = _disposeFuture;
    if (existingDispose != null) {
      return existingDispose;
    }

    _isDisposeRequested = true;
    return _disposeFuture = _enqueue(() async {
      try {
        if (_activeStream != null) {
          await _recorder.stop();
        }
      } finally {
        _activeStream = null;
        _isPaused = false;
        _isDisposed = true;
        await _recorder.dispose();
      }
    });
  }

  void _throwIfDisposed() {
    if (_isDisposed) {
      throw StateError('Microphone capture has been disposed.');
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final scheduled = _operationTail.then((_) => operation());
    _operationTail = scheduled.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return scheduled;
  }
}

class _RecordAudioRecorderDriver implements AudioRecorderDriver {
  _RecordAudioRecorderDriver() : _recorder = AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<void> dispose() => _recorder.dispose();

  @override
  Future<void> pause() => _recorder.pause();

  @override
  Future<void> resume() => _recorder.resume();

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) =>
      _recorder.startStream(config);

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }
}

/// Provider-free capture for debug-only bindings before microphone wiring.
class DebugNoopMicrophoneCapture implements MobileMicrophoneCapture {
  final StreamController<Uint8List> _audioController =
      StreamController<Uint8List>.broadcast(sync: true);
  bool _isDisposed = false;

  @override
  Future<Stream<Uint8List>> start() async {
    if (_isDisposed) {
      throw StateError('Microphone capture has been disposed.');
    }
    return _audioController.stream;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    await _audioController.close();
  }
}

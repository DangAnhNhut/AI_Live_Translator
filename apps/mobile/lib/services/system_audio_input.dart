import 'dart:async';

import 'package:flutter/services.dart';

import 'audio_input.dart';

abstract interface class SystemAudioPlatformBridge {
  Stream<Object?> get events;

  Future<bool> isSupported();

  Future<void> start();

  Future<void> stop();
}

class MethodChannelSystemAudioPlatformBridge
    implements SystemAudioPlatformBridge {
  MethodChannelSystemAudioPlatformBridge({
    MethodChannel methodChannel = const MethodChannel(
      'ai_live_translator/system_audio/methods',
    ),
    Stream<Object?>? eventStream,
  }) : _methodChannel = methodChannel,
       _events =
           eventStream ??
           const EventChannel(
             'ai_live_translator/system_audio/events',
           ).receiveBroadcastStream();

  final MethodChannel _methodChannel;
  final Stream<Object?> _events;

  @override
  Stream<Object?> get events => _events;

  @override
  Future<bool> isSupported() async {
    return await _methodChannel.invokeMethod<bool>('isSupported') ?? false;
  }

  @override
  Future<void> start() => _methodChannel.invokeMethod<void>('start');

  @override
  Future<void> stop() => _methodChannel.invokeMethod<void>('stop');
}

class SystemAudioInput implements MobileAudioInput {
  SystemAudioInput({required SystemAudioPlatformBridge platform})
    : _platform = platform;

  final SystemAudioPlatformBridge _platform;

  StreamController<Uint8List>? _pcmController;
  StreamSubscription<Object?>? _eventSubscription;
  Future<void>? _stopFuture;
  bool _isStarted = false;
  bool _isPaused = false;
  bool _isDisposed = false;
  bool _endedDuringStart = false;

  Future<bool> isSupported() async {
    if (_isDisposed) {
      return false;
    }
    try {
      return await _platform.isSupported();
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<Stream<Uint8List>> start() async {
    if (_isDisposed) {
      throw StateError('System Audio input has been disposed.');
    }
    final activeController = _pcmController;
    if (_isStarted && activeController != null) {
      return activeController.stream;
    }

    final controller = StreamController<Uint8List>.broadcast(sync: true);
    _endedDuringStart = false;
    _pcmController = controller;
    _eventSubscription = _platform.events.listen(
      _handlePlatformEvent,
      onError: _handlePlatformStreamError,
      onDone: _handlePlatformStreamDone,
    );

    try {
      await _platform.start();
      if (_endedDuringStart) {
        throw _errorForCode('projection_stopped');
      }
      _isStarted = true;
      _isPaused = false;
      return controller.stream;
    } catch (error) {
      await _closeLocalStream();
      try {
        await _platform.stop();
      } catch (_) {
        // Preserve the controlled start failure even if cleanup also fails.
      }
      throw _mapPlatformError(error);
    }
  }

  @override
  Future<void> pause() async {
    if (_isDisposed || !_isStarted) {
      return;
    }
    _isPaused = true;
  }

  @override
  Future<void> resume() async {
    if (_isDisposed || !_isStarted) {
      return;
    }
    _isPaused = false;
  }

  @override
  Future<void> stop() {
    final activeStop = _stopFuture;
    if (activeStop != null) {
      return activeStop;
    }
    if (!_isStarted && _pcmController == null) {
      return Future<void>.value();
    }

    late final Future<void> sharedStop;
    sharedStop = _performStop().whenComplete(() {
      if (identical(_stopFuture, sharedStop)) {
        _stopFuture = null;
      }
    });
    _stopFuture = sharedStop;
    return sharedStop;
  }

  Future<void> _performStop() async {
    _isStarted = false;
    _isPaused = false;
    await _closeLocalStream();
    try {
      await _platform.stop();
    } on PlatformException {
      // Native cleanup is idempotent; local cleanup still completes.
    }
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    await stop();
    _isDisposed = true;
  }

  void _handlePlatformEvent(Object? event) {
    if (!_isStarted && _pcmController == null) {
      return;
    }
    if (event is! Map<Object?, Object?>) {
      return;
    }
    final type = event['type'];
    if (type == 'pcm') {
      final data = event['data'];
      if (!_isPaused && data is Uint8List) {
        _pcmController?.add(data);
      }
      return;
    }
    if (type == 'ended') {
      if (!_isStarted) {
        _endedDuringStart = true;
      }
      _isStarted = false;
      _isPaused = false;
      unawaited(_closeLocalStream());
      return;
    }
    if (type == 'error') {
      final code = event['code'];
      _pcmController?.addError(
        _errorForCode(code is String ? code : 'capture_failed'),
      );
    }
  }

  void _handlePlatformStreamError(Object error, StackTrace stackTrace) {
    _pcmController?.addError(_mapPlatformError(error), stackTrace);
  }

  void _handlePlatformStreamDone() {
    if (!_isStarted) {
      _endedDuringStart = true;
    }
    _isStarted = false;
    _isPaused = false;
    unawaited(_closeLocalStream());
  }

  Future<void> _closeLocalStream() async {
    final subscription = _eventSubscription;
    _eventSubscription = null;
    if (subscription != null) {
      await subscription.cancel();
    }
    final controller = _pcmController;
    _pcmController = null;
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }
}

AudioInputException _mapPlatformError(Object error) {
  if (error is AudioInputException) {
    return error;
  }
  if (error is PlatformException) {
    return _errorForCode(error.code);
  }
  return _errorForCode('capture_failed');
}

AudioInputException _errorForCode(String code) {
  return AudioInputException(
    code: code,
    message: switch (code) {
      'unsupported' => 'System Audio requires Android 10 or later.',
      'projection_cancelled' => 'System Audio permission was cancelled.',
      'unsupported_capture_format' =>
        'This device cannot provide 16 kHz mono System Audio.',
      'foreground_service_failed' =>
        'Unable to prepare protected System Audio capture.',
      'projection_failed' => 'Unable to start System Audio sharing.',
      'audio_record_failed' => 'Unable to start System Audio capture.',
      'projection_stopped' => 'System Audio sharing stopped unexpectedly.',
      _ => 'System Audio capture failed.',
    },
  );
}

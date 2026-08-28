import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/microphone_capture_service.dart';
import '../services/microphone_permission_service.dart';
import '../services/stt_websocket_service.dart';
import 'live_session_state.dart';
import 'session_timer.dart';

typedef RetryDelay = Future<void> Function(Duration duration);

class LiveSessionController extends ChangeNotifier {
  LiveSessionController({
    required MicrophonePermissionGateway permissionGateway,
    required SttSessionTransport transport,
    MobileMicrophoneCapture? microphoneCapture,
    SessionClock? clock,
    SessionTicker? ticker,
    this.maxReconnectAttempts = 3,
    this.reconnectDelay = const Duration(milliseconds: 500),
    RetryDelay? retryDelay,
  }) : _permissionGateway = permissionGateway,
       _transport = transport,
       _microphoneCapture = microphoneCapture ?? DebugNoopMicrophoneCapture(),
       _clock = clock ?? StopwatchSessionClock(),
       _ticker = ticker ?? PeriodicSessionTicker(),
       _retryDelay = retryDelay ?? Future<void>.delayed,
       assert(maxReconnectAttempts > 0) {
    _eventSubscription = _transport.events.listen(_handleTransportEvent);
  }

  final MicrophonePermissionGateway _permissionGateway;
  final SttSessionTransport _transport;
  final MobileMicrophoneCapture _microphoneCapture;
  final SessionClock _clock;
  final SessionTicker _ticker;
  final RetryDelay _retryDelay;
  final int maxReconnectAttempts;
  final Duration reconnectDelay;
  late final StreamSubscription<SttSessionEvent> _eventSubscription;
  StreamSubscription<Uint8List>? _audioSubscription;
  Future<void>? _audioSendFuture;

  LiveSessionState _state = LiveSessionState.ready;
  String? _errorMessage;
  bool _canOpenAppSettings = false;
  bool _canRetry = false;
  LiveSessionRetryKind? _retryKind;
  bool _restorePausedAfterReconnect = false;
  Duration _accumulatedElapsed = Duration.zero;
  Duration? _listeningStartedAt;
  final Map<String, String> _transcriptSegments = {};
  int _operationGeneration = 0;
  int _freshRetryGeneration = 0;
  Future<void>? _stopFuture;
  Future<void>? _freshRetryFuture;
  Future<void>? _microphonePauseFuture;
  Future<void>? _microphoneFailureCleanupFuture;
  bool _forwardAudio = false;
  bool _microphonePaused = false;
  bool _isDisposed = false;

  LiveSessionState get state => _state;
  Duration get elapsed =>
      _accumulatedElapsed +
      (_listeningStartedAt == null
          ? Duration.zero
          : _clock.now - _listeningStartedAt!);
  String? get errorMessage => _errorMessage;
  bool get canOpenAppSettings => _canOpenAppSettings;
  bool get canRetry => _canRetry;
  String get transcript => _transcriptSegments.values.join('\n');

  Future<void> start() async {
    if (_isDisposed || _state != LiveSessionState.ready) {
      return;
    }
    final operationGeneration = ++_operationGeneration;

    _errorMessage = null;
    _canOpenAppSettings = false;
    _canRetry = false;
    _retryKind = null;
    _restorePausedAfterReconnect = false;
    _state = LiveSessionState.permission;
    _notifyListeners();

    late final MicrophonePermissionResult permission;
    try {
      permission = await _permissionGateway.requestPermission();
    } catch (_) {
      if (operationGeneration != _operationGeneration ||
          _state != LiveSessionState.permission) {
        return;
      }
      _errorMessage = 'Unable to request microphone permission.';
      _canRetry = true;
      _retryKind = LiveSessionRetryKind.freshStart;
      _state = LiveSessionState.error;
      _notifyListeners();
      return;
    }
    if (operationGeneration != _operationGeneration ||
        _state != LiveSessionState.permission) {
      return;
    }
    if (permission != MicrophonePermissionResult.granted) {
      _canOpenAppSettings =
          permission == MicrophonePermissionResult.permanentlyDenied;
      _canRetry = true;
      _retryKind = LiveSessionRetryKind.freshStart;
      _errorMessage = permission == MicrophonePermissionResult.denied
          ? 'Microphone permission is required to start a live session.'
          : 'Microphone permission is permanently denied. Open app settings to enable it.';
      _state = LiveSessionState.error;
      _notifyListeners();
      return;
    }

    _state = LiveSessionState.connecting;
    _notifyListeners();

    try {
      await _transport.connect();
    } catch (error) {
      if (operationGeneration != _operationGeneration ||
          _state != LiveSessionState.connecting) {
        return;
      }
      _errorMessage = error is SttSessionException
          ? error.message
          : 'WebSocket connection failed. Check that the backend is available.';
      _canRetry = error is SttSessionException ? error.recoverable : true;
      _retryKind = _canRetry ? LiveSessionRetryKind.freshStart : null;
      _state = LiveSessionState.error;
      _notifyListeners();
      return;
    }
    if (operationGeneration != _operationGeneration ||
        _state != LiveSessionState.connecting) {
      return;
    }

    try {
      final audioStream = await _microphoneCapture.start();
      if (operationGeneration != _operationGeneration ||
          _state != LiveSessionState.connecting ||
          _isDisposed) {
        await _stopMicrophoneSafely();
        return;
      }
      _audioSubscription = audioStream.listen(
        _handleAudioChunk,
        onError: _handleAudioStreamError,
        onDone: _handleAudioStreamDone,
      );
    } catch (_) {
      _forwardAudio = false;
      await _stopMicrophoneSafely();
      await _disconnectTransportSafely();
      if (operationGeneration != _operationGeneration ||
          _state != LiveSessionState.connecting ||
          _isDisposed) {
        return;
      }
      _errorMessage = 'Unable to start microphone capture.';
      _canRetry = true;
      _retryKind = LiveSessionRetryKind.freshStart;
      _state = LiveSessionState.error;
      _notifyListeners();
      return;
    }

    _microphonePaused = false;
    _forwardAudio = true;
    _state = LiveSessionState.listening;
    _retryKind = null;
    _restorePausedAfterReconnect = false;
    _startTimer();
    _notifyListeners();
  }

  Future<bool> openAppSettings() async {
    if (!_canOpenAppSettings) {
      return false;
    }
    return _permissionGateway.openAppSettings();
  }

  Future<void> retry() {
    final retryKind = _retryKind;
    if (_state != LiveSessionState.error || !_canRetry || retryKind == null) {
      return Future<void>.value();
    }
    if (retryKind == LiveSessionRetryKind.activeSessionReconnect) {
      _errorMessage = null;
      _canOpenAppSettings = false;
      _canRetry = false;
      _retryKind = null;
      _state = LiveSessionState.reconnecting;
      _notifyListeners();
      final operationGeneration = ++_operationGeneration;
      return _pauseThenReconnect(operationGeneration);
    }
    final activeRetry = _freshRetryFuture;
    if (activeRetry != null) {
      return activeRetry;
    }
    final freshRetryGeneration = ++_freshRetryGeneration;
    late final Future<void> sharedRetry;
    sharedRetry = _retryFresh(freshRetryGeneration).whenComplete(() {
      if (identical(_freshRetryFuture, sharedRetry)) {
        _freshRetryFuture = null;
      }
    });
    _freshRetryFuture = sharedRetry;
    return sharedRetry;
  }

  Future<void> _retryFresh(int freshRetryGeneration) async {
    await _stopSession();
    if (freshRetryGeneration != _freshRetryGeneration) {
      return;
    }
    await start();
  }

  Future<void> pause() async {
    if (_isDisposed || _state != LiveSessionState.listening) {
      return;
    }

    _forwardAudio = false;
    _freezeTimer();
    _state = LiveSessionState.paused;
    _notifyListeners();
    await _pauseMicrophone();
  }

  Future<void> resume() async {
    if (_isDisposed || _state != LiveSessionState.paused) {
      return;
    }

    final operationGeneration = _operationGeneration;
    try {
      await _microphoneCapture.resume();
    } catch (_) {
      return;
    }
    if (_isDisposed ||
        operationGeneration != _operationGeneration ||
        _state != LiveSessionState.paused) {
      return;
    }
    _microphonePaused = false;
    _forwardAudio = true;
    _state = LiveSessionState.listening;
    _startTimer();
    _notifyListeners();
  }

  Future<void> stop() {
    _forwardAudio = false;
    _freshRetryGeneration++;
    return _stopSession();
  }

  Future<void> _stopSession() {
    final activeStop = _stopFuture;
    if (activeStop != null) {
      return activeStop;
    }
    if (_state == LiveSessionState.ready) {
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
    _operationGeneration++;
    _forwardAudio = false;

    final shouldSendStop =
        _state == LiveSessionState.listening ||
        _state == LiveSessionState.paused ||
        _state == LiveSessionState.reconnecting ||
        (_state == LiveSessionState.error &&
            _retryKind == LiveSessionRetryKind.activeSessionReconnect);
    _freezeTimer();

    await _waitForMicrophoneFailureCleanup();
    await _cancelAudioSubscription();
    await _stopMicrophoneSafely();
    await _waitForAudioSend();

    try {
      if (shouldSendStop) {
        await _transport.stop();
      }
    } catch (_) {
      // Local cleanup must still complete when the remote session is gone.
    } finally {
      try {
        await _transport.disconnect();
      } catch (_) {
        // Stop remains deterministic even if transport cleanup reports failure.
      }
    }

    _accumulatedElapsed = Duration.zero;
    _transcriptSegments.clear();
    _errorMessage = null;
    _canOpenAppSettings = false;
    _canRetry = false;
    _retryKind = null;
    _restorePausedAfterReconnect = false;
    _state = LiveSessionState.ready;
    _notifyListeners();
  }

  void _handleAudioChunk(Uint8List audio) {
    if (_isDisposed || !_forwardAudio || _state != LiveSessionState.listening) {
      return;
    }

    final operationGeneration = _operationGeneration;
    final previousSend = _audioSendFuture;
    final sendFuture = previousSend == null
        ? _sendAudioIfCurrent(audio, operationGeneration)
        : previousSend.then(
            (_) => _sendAudioIfCurrent(audio, operationGeneration),
          );

    late final Future<void> sharedSend;
    sharedSend = sendFuture
        .catchError((Object _, StackTrace _) {})
        .whenComplete(() {
          if (!identical(_audioSendFuture, sharedSend)) {
            return;
          }
          _audioSendFuture = null;
        });
    _audioSendFuture = sharedSend;
  }

  Future<void> _sendAudioIfCurrent(
    Uint8List audio,
    int operationGeneration,
  ) {
    if (_isDisposed ||
        !_forwardAudio ||
        operationGeneration != _operationGeneration ||
        _state != LiveSessionState.listening) {
      return Future<void>.value();
    }
    try {
      return _transport.sendAudio(audio);
    } catch (_) {
      // A synchronous socket failure is contained like an asynchronous one.
      return Future<void>.value();
    }
  }

  void _handleAudioStreamDone() {
    _audioSubscription = null;
    _handleUnexpectedMicrophoneEnd();
  }

  void _handleAudioStreamError(Object _, StackTrace _) {
    final subscription = _audioSubscription;
    _audioSubscription = null;
    final cancelFuture = subscription?.cancel();
    _handleUnexpectedMicrophoneEnd(cancelFuture: cancelFuture);
  }

  void _handleUnexpectedMicrophoneEnd({Future<void>? cancelFuture}) {
    if (_isDisposed || !_forwardAudio || _state != LiveSessionState.listening) {
      return;
    }

    _forwardAudio = false;
    _operationGeneration++;
    _freezeTimer();
    _errorMessage = 'Microphone capture stopped unexpectedly.';
    _canOpenAppSettings = false;
    _canRetry = true;
    _retryKind = LiveSessionRetryKind.freshStart;
    _restorePausedAfterReconnect = false;
    _state = LiveSessionState.error;
    _notifyListeners();

    late final Future<void> sharedCleanup;
    sharedCleanup = _cleanupUnexpectedMicrophoneEnd(cancelFuture).whenComplete(
      () {
        if (identical(_microphoneFailureCleanupFuture, sharedCleanup)) {
          _microphoneFailureCleanupFuture = null;
        }
      },
    );
    _microphoneFailureCleanupFuture = sharedCleanup;
  }

  Future<void> _cleanupUnexpectedMicrophoneEnd(
    Future<void>? cancelFuture,
  ) async {
    if (cancelFuture != null) {
      try {
        await cancelFuture;
      } catch (_) {
        // Continue cleanup even if the failed stream cannot be cancelled.
      }
    }
    await _stopMicrophoneSafely();
    await _waitForAudioSend();
    await _disconnectTransportSafely();
  }

  Future<void> _waitForMicrophoneFailureCleanup() async {
    final cleanupFuture = _microphoneFailureCleanupFuture;
    if (cleanupFuture == null) {
      return;
    }
    try {
      await cleanupFuture;
    } catch (_) {
      // Cleanup helpers already sanitize platform and transport failures.
    }
  }

  Future<void> _pauseMicrophone() {
    if (_microphonePaused) {
      return Future<void>.value();
    }
    final activePause = _microphonePauseFuture;
    if (activePause != null) {
      return activePause;
    }
    late final Future<void> sharedPause;
    sharedPause = _microphoneCapture
        .pause()
        .catchError((Object _, StackTrace _) {})
        .whenComplete(() {
          _microphonePaused = true;
          if (identical(_microphonePauseFuture, sharedPause)) {
            _microphonePauseFuture = null;
          }
        });
    _microphonePauseFuture = sharedPause;
    return sharedPause;
  }

  Future<void> _cancelAudioSubscription() async {
    final subscription = _audioSubscription;
    _audioSubscription = null;
    if (subscription == null) {
      return;
    }
    try {
      await subscription.cancel();
    } catch (_) {
      // Remaining local and transport cleanup must still run.
    }
  }

  Future<void> _waitForAudioSend() async {
    final sendFuture = _audioSendFuture;
    if (sendFuture == null) {
      return;
    }
    try {
      await sendFuture;
    } catch (_) {
      // Audio send failures are already normalized by the transport lifecycle.
    }
  }

  Future<void> _stopMicrophoneSafely() async {
    try {
      await _microphoneCapture.stop();
    } catch (_) {
      // Remaining transport cleanup must still run.
    }
    _microphonePaused = false;
  }

  Future<void> _disconnectTransportSafely() async {
    try {
      await _transport.disconnect();
    } catch (_) {
      // Local lifecycle transitions must not expose cleanup details.
    }
  }

  void _notifyListeners() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  void _startTimer() {
    if (_listeningStartedAt != null) {
      return;
    }
    _listeningStartedAt = _clock.now;
    _ticker.start(_notifyListeners);
  }

  void _freezeTimer() {
    final listeningStartedAt = _listeningStartedAt;
    if (listeningStartedAt == null) {
      return;
    }
    _accumulatedElapsed += _clock.now - listeningStartedAt;
    _listeningStartedAt = null;
    _ticker.stop();
  }

  void _handleTransportEvent(SttSessionEvent event) {
    if (_isDisposed) {
      return;
    }
    if (event is SttTranscriptEvent) {
      _transcriptSegments[event.segmentId] = event.text;
      _notifyListeners();
      return;
    }
    if (event is SttSessionErrorEvent &&
        (_state == LiveSessionState.connecting ||
            _state == LiveSessionState.listening ||
            _state == LiveSessionState.paused ||
            _state == LiveSessionState.reconnecting)) {
      final restorePaused =
          _state == LiveSessionState.paused ||
          (_state == LiveSessionState.reconnecting &&
              _restorePausedAfterReconnect);
      final retryKind = _state == LiveSessionState.connecting
          ? LiveSessionRetryKind.freshStart
          : LiveSessionRetryKind.activeSessionReconnect;
      _forwardAudio = false;
      if (_state == LiveSessionState.listening) {
        unawaited(_pauseMicrophone());
      }
      _operationGeneration++;
      _freezeTimer();
      _errorMessage = event.message;
      _canRetry = event.recoverable;
      _retryKind = event.recoverable ? retryKind : null;
      _restorePausedAfterReconnect =
          event.recoverable &&
          retryKind == LiveSessionRetryKind.activeSessionReconnect &&
          restorePaused;
      _state = LiveSessionState.error;
      _notifyListeners();
      return;
    }
    if (event is SttSessionClosedEvent &&
        event.unexpected &&
        (_state == LiveSessionState.listening ||
            _state == LiveSessionState.paused)) {
      _restorePausedAfterReconnect = _state == LiveSessionState.paused;
      _forwardAudio = false;
      _freezeTimer();
      _state = LiveSessionState.reconnecting;
      _notifyListeners();
      final operationGeneration = ++_operationGeneration;
      unawaited(_pauseThenReconnect(operationGeneration));
    }
  }

  Future<void> _pauseThenReconnect(int operationGeneration) async {
    await _pauseMicrophone();
    if (_isDisposed ||
        operationGeneration != _operationGeneration ||
        _state != LiveSessionState.reconnecting) {
      return;
    }
    await _reconnect(operationGeneration);
  }

  Future<void> _reconnect(int operationGeneration) async {
    await _waitForAudioSend();
    if (_isDisposed ||
        operationGeneration != _operationGeneration ||
        _state != LiveSessionState.reconnecting) {
      return;
    }

    for (var attempt = 1; attempt <= maxReconnectAttempts; attempt++) {
      if (operationGeneration != _operationGeneration ||
          _state != LiveSessionState.reconnecting) {
        return;
      }
      try {
        await _transport.disconnect();
        if (operationGeneration != _operationGeneration ||
            _state != LiveSessionState.reconnecting) {
          return;
        }
        await _transport.connect();
        if (operationGeneration != _operationGeneration ||
            _state != LiveSessionState.reconnecting) {
          return;
        }
        final restorePaused = _restorePausedAfterReconnect;
        if (!restorePaused) {
          await _microphoneCapture.resume();
          if (_isDisposed ||
              operationGeneration != _operationGeneration ||
              _state != LiveSessionState.reconnecting) {
            return;
          }
          _microphonePaused = false;
          _forwardAudio = true;
        }
        _state = restorePaused
            ? LiveSessionState.paused
            : LiveSessionState.listening;
        _retryKind = null;
        _restorePausedAfterReconnect = false;
        if (!restorePaused) {
          _startTimer();
        }
        _notifyListeners();
        return;
      } catch (error) {
        if (operationGeneration != _operationGeneration ||
            _state != LiveSessionState.reconnecting) {
          return;
        }
        final terminalProtocolError =
            error is SttSessionException && !error.recoverable;
        if (terminalProtocolError || attempt == maxReconnectAttempts) {
          _errorMessage = terminalProtocolError
              ? error.message
              : 'Unable to reconnect to the STT session.';
          _canRetry = !terminalProtocolError;
          _retryKind = terminalProtocolError
              ? null
              : LiveSessionRetryKind.activeSessionReconnect;
          if (terminalProtocolError) {
            _restorePausedAfterReconnect = false;
          }
          _state = LiveSessionState.error;
          _notifyListeners();
          return;
        }
        await _retryDelay(reconnectDelay);
      }
    }
  }

  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _forwardAudio = false;
    _operationGeneration++;
    _ticker.dispose();
    unawaited(_performDispose());
    super.dispose();
  }

  Future<void> _performDispose() async {
    try {
      await _eventSubscription.cancel();
    } catch (_) {
      // Continue disposal even if the event stream is already gone.
    }
    await _waitForMicrophoneFailureCleanup();
    await _cancelAudioSubscription();
    try {
      await _microphoneCapture.dispose();
    } catch (_) {
      // Transport cleanup must still run.
    }
    await _waitForAudioSend();
    await _disconnectTransportSafely();
  }
}

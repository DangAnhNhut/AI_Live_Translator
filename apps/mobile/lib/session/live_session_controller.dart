import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/microphone_permission_service.dart';
import '../services/stt_websocket_service.dart';
import 'live_session_state.dart';
import 'session_timer.dart';

typedef RetryDelay = Future<void> Function(Duration duration);

class LiveSessionController extends ChangeNotifier {
  LiveSessionController({
    required MicrophonePermissionGateway permissionGateway,
    required SttSessionTransport transport,
    SessionClock? clock,
    SessionTicker? ticker,
    this.maxReconnectAttempts = 3,
    this.reconnectDelay = const Duration(milliseconds: 500),
    RetryDelay? retryDelay,
  }) : _permissionGateway = permissionGateway,
       _transport = transport,
       _clock = clock ?? StopwatchSessionClock(),
       _ticker = ticker ?? PeriodicSessionTicker(),
       _retryDelay = retryDelay ?? Future<void>.delayed,
       assert(maxReconnectAttempts > 0) {
    _eventSubscription = _transport.events.listen(_handleTransportEvent);
  }

  final MicrophonePermissionGateway _permissionGateway;
  final SttSessionTransport _transport;
  final SessionClock _clock;
  final SessionTicker _ticker;
  final RetryDelay _retryDelay;
  final int maxReconnectAttempts;
  final Duration reconnectDelay;
  late final StreamSubscription<SttSessionEvent> _eventSubscription;

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
    if (_state != LiveSessionState.ready) {
      return;
    }
    final operationGeneration = ++_operationGeneration;

    _errorMessage = null;
    _canOpenAppSettings = false;
    _canRetry = false;
    _retryKind = null;
    _restorePausedAfterReconnect = false;
    _state = LiveSessionState.permission;
    notifyListeners();

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
      notifyListeners();
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
      notifyListeners();
      return;
    }

    _state = LiveSessionState.connecting;
    notifyListeners();

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
      notifyListeners();
      return;
    }
    if (operationGeneration != _operationGeneration ||
        _state != LiveSessionState.connecting) {
      return;
    }

    _state = LiveSessionState.listening;
    _retryKind = null;
    _restorePausedAfterReconnect = false;
    _startTimer();
    notifyListeners();
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
      notifyListeners();
      final operationGeneration = ++_operationGeneration;
      return _reconnect(operationGeneration);
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

  void pause() {
    if (_state != LiveSessionState.listening) {
      return;
    }

    _freezeTimer();
    // Task 5 has no microphone stream yet. This transition deliberately owns
    // session/timer state so audio pause can be attached here later.
    _state = LiveSessionState.paused;
    notifyListeners();
  }

  void resume() {
    if (_state != LiveSessionState.paused) {
      return;
    }

    // Task 5 resumes session/timer state only; no audio stream exists yet.
    _state = LiveSessionState.listening;
    _startTimer();
    notifyListeners();
  }

  Future<void> stop() {
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

    final shouldSendStop =
        _state == LiveSessionState.listening ||
        _state == LiveSessionState.paused ||
        _state == LiveSessionState.reconnecting ||
        (_state == LiveSessionState.error &&
            _retryKind == LiveSessionRetryKind.activeSessionReconnect);
    _freezeTimer();

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
    notifyListeners();
  }

  void _startTimer() {
    if (_listeningStartedAt != null) {
      return;
    }
    _listeningStartedAt = _clock.now;
    _ticker.start(notifyListeners);
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
    if (event is SttTranscriptEvent) {
      _transcriptSegments[event.segmentId] = event.text;
      notifyListeners();
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
      notifyListeners();
      return;
    }
    if (event is SttSessionClosedEvent &&
        event.unexpected &&
        (_state == LiveSessionState.listening ||
            _state == LiveSessionState.paused)) {
      _restorePausedAfterReconnect = _state == LiveSessionState.paused;
      _freezeTimer();
      _state = LiveSessionState.reconnecting;
      notifyListeners();
      final operationGeneration = ++_operationGeneration;
      unawaited(_reconnect(operationGeneration));
    }
  }

  Future<void> _reconnect(int operationGeneration) async {
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
        _state = restorePaused
            ? LiveSessionState.paused
            : LiveSessionState.listening;
        _retryKind = null;
        _restorePausedAfterReconnect = false;
        if (!restorePaused) {
          _startTimer();
        }
        notifyListeners();
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
          notifyListeners();
          return;
        }
        await _retryDelay(reconnectDelay);
      }
    }
  }

  @override
  void dispose() {
    _operationGeneration++;
    unawaited(_eventSubscription.cancel());
    _ticker.dispose();
    unawaited(_transport.disconnect());
    super.dispose();
  }
}

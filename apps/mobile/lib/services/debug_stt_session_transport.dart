import 'dart:async';

import 'stt_websocket_service.dart';

/// Optional controls exposed only when the debug transport is selected.
abstract interface class DebugSttSessionControls {
  bool get hasPendingReconnect;

  void configureNextReconnectToWait();

  void completeReconnectSuccessfully();

  void configureReconnectsToFail();

  Future<void> simulateUnexpectedDisconnect();
}

class DebugSttSessionException extends SttSessionException {
  const DebugSttSessionException()
    : super(
        code: 'debug_reconnect_failure',
        message: 'Debug reconnect attempt failed.',
        recoverable: true,
      );
}

/// Manual-verification transport used only by the guarded debug app binding.
///
/// It simulates session readiness and connection loss, but never captures
/// audio or emits transcript/STT result events.
class DebugSttSessionTransport
    implements SttSessionTransport, DebugSttSessionControls {
  DebugSttSessionTransport({
    this.initialConnectDelay = const Duration(milliseconds: 750),
    this.reconnectFailureAttempts = 3,
  }) : assert(reconnectFailureAttempts > 0);

  final Duration initialConnectDelay;
  final int reconnectFailureAttempts;
  final StreamController<SttSessionEvent> _eventsController =
      StreamController<SttSessionEvent>.broadcast();

  bool _isConnected = false;
  bool _hasConnectedOnce = false;
  bool _holdNextReconnect = false;
  int _remainingReconnectFailures = 0;
  Completer<void>? _pendingReconnect;
  int _operationGeneration = 0;

  bool get isConnected => _isConnected;

  @override
  bool get hasPendingReconnect => _pendingReconnect != null;

  @override
  Stream<SttSessionEvent> get events => _eventsController.stream;

  @override
  Future<void> connect() async {
    final operationGeneration = ++_operationGeneration;
    if (_hasConnectedOnce && _remainingReconnectFailures > 0) {
      _remainingReconnectFailures--;
      throw const DebugSttSessionException();
    }
    if (_hasConnectedOnce && _holdNextReconnect) {
      _holdNextReconnect = false;
      final reconnect = Completer<void>();
      _pendingReconnect = reconnect;
      await reconnect.future;
      if (identical(_pendingReconnect, reconnect)) {
        _pendingReconnect = null;
      }
      if (operationGeneration != _operationGeneration) {
        return;
      }
      _isConnected = true;
      return;
    }
    await Future<void>.delayed(initialConnectDelay);
    if (operationGeneration != _operationGeneration) {
      return;
    }
    _isConnected = true;
    _hasConnectedOnce = true;
  }

  @override
  void configureNextReconnectToWait() {
    _remainingReconnectFailures = 0;
    _holdNextReconnect = true;
  }

  @override
  void completeReconnectSuccessfully() {
    final reconnect = _pendingReconnect;
    if (reconnect != null && !reconnect.isCompleted) {
      reconnect.complete();
    }
  }

  @override
  void configureReconnectsToFail() {
    _holdNextReconnect = false;
    _remainingReconnectFailures = reconnectFailureAttempts;
  }

  @override
  Future<void> simulateUnexpectedDisconnect() async {
    if (!_isConnected) {
      return;
    }
    _isConnected = false;
    _eventsController.add(const SttSessionClosedEvent(unexpected: true));
  }

  @override
  Future<void> stop() async {
    _holdNextReconnect = false;
    _remainingReconnectFailures = 0;
    _hasConnectedOnce = false;
    await disconnect();
  }

  @override
  Future<void> disconnect() async {
    _operationGeneration++;
    _isConnected = false;
    final reconnect = _pendingReconnect;
    _pendingReconnect = null;
    if (reconnect != null && !reconnect.isCompleted) {
      reconnect.complete();
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _eventsController.close();
  }
}

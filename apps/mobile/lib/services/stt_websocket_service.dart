import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'realtime_websocket_service.dart';

sealed class SttSessionEvent {
  const SttSessionEvent();
}

class SttSessionErrorEvent extends SttSessionEvent {
  const SttSessionErrorEvent({
    required this.code,
    required this.message,
    required this.recoverable,
  });

  final String code;
  final String message;
  final bool recoverable;
}

enum SttTranscriptKind { interim, finalResult }

class SttTranscriptEvent extends SttSessionEvent {
  const SttTranscriptEvent({
    required this.kind,
    required this.segmentId,
    required this.text,
    required this.language,
  });

  final SttTranscriptKind kind;
  final String segmentId;
  final String text;
  final String language;
}

class SttSessionClosedEvent extends SttSessionEvent {
  const SttSessionClosedEvent({required this.unexpected});

  final bool unexpected;
}

class SttSessionException implements Exception {
  const SttSessionException({
    required this.code,
    required this.message,
    required this.recoverable,
  });

  final String code;
  final String message;
  final bool recoverable;

  @override
  String toString() => 'SttSessionException($code): $message';
}

const _connectionCancelledException = SttSessionException(
  code: 'connection_cancelled',
  message: 'The STT connection attempt was cancelled.',
  recoverable: true,
);

class _SttConnectAttempt {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get cancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }
}

abstract interface class SttSessionTransport {
  Stream<SttSessionEvent> get events;

  Future<void> connect();

  Future<void> sendAudio(Uint8List audio);

  Future<void> stop();

  Future<void> disconnect();
}

class SttWebSocketService implements SttSessionTransport {
  SttWebSocketService({
    required this.baseUrl,
    required SocketConnector connector,
    this.connectionTimeout = const Duration(seconds: 5),
  }) : _connector = connector;

  final String baseUrl;
  final SocketConnector _connector;
  final Duration connectionTimeout;
  final StreamController<SttSessionEvent> _eventsController =
      StreamController<SttSessionEvent>.broadcast();

  SocketConnection? _socket;
  StreamSubscription<dynamic>? _subscription;
  Future<void>? _connectFuture;
  _SttConnectAttempt? _connectAttempt;
  bool _isReady = false;

  @override
  Stream<SttSessionEvent> get events => _eventsController.stream;

  @override
  Future<void> connect() {
    final activeConnect = _connectFuture;
    if (activeConnect != null) {
      return activeConnect;
    }

    final attempt = _SttConnectAttempt();
    _connectAttempt = attempt;
    late final Future<void> sharedConnect;
    sharedConnect = _connect(attempt).whenComplete(() {
      if (identical(_connectFuture, sharedConnect)) {
        _connectFuture = null;
      }
    });
    _connectFuture = sharedConnect;
    return sharedConnect;
  }

  Future<void> _connect(_SttConnectAttempt attempt) async {
    try {
      _isReady = false;
      await _closeSocket();
      final socketFuture = _connector(
        Uri.parse('$baseUrl/ws/stt'),
      ).timeout(connectionTimeout);
      unawaited(
        socketFuture
            .then<void>((socket) async {
              if (attempt.isCancelled) {
                await socket.close();
              }
            })
            .catchError((Object _) {}),
      );
      final socket = await Future.any<SocketConnection>([
        socketFuture,
        attempt.cancelled.then<SocketConnection>(
          (_) => throw _connectionCancelledException,
        ),
      ]);
      if (attempt.isCancelled) {
        await socket.close();
        throw _connectionCancelledException;
      }
      final ready = Completer<void>();
      var closedEventSent = false;
      _socket = socket;
      _subscription = socket.stream.listen(
        (message) {
          if (attempt.isCancelled || !identical(_connectAttempt, attempt)) {
            return;
          }
          if (message is! String) {
            return;
          }
          Object? payload;
          try {
            payload = jsonDecode(message);
          } on FormatException {
            const exception = SttSessionException(
              code: 'invalid_server_message',
              message: 'Received an invalid STT server message.',
              recoverable: false,
            );
            _eventsController.add(
              const SttSessionErrorEvent(
                code: 'invalid_server_message',
                message: 'Received an invalid STT server message.',
                recoverable: false,
              ),
            );
            if (!ready.isCompleted) {
              ready.completeError(exception);
            }
            return;
          }
          if (payload is Map<String, dynamic>) {
            if (payload['type'] == 'stt.ready' && !ready.isCompleted) {
              _isReady = true;
              ready.complete();
              return;
            }
            if (payload['type'] == 'stt.closed') {
              _isReady = false;
              if (!closedEventSent) {
                closedEventSent = true;
                _eventsController.add(
                  const SttSessionClosedEvent(unexpected: false),
                );
              }
              if (!ready.isCompleted) {
                ready.completeError(
                  const SttSessionException(
                    code: 'session_closed',
                    message: 'The STT session closed before it was ready.',
                    recoverable: true,
                  ),
                );
              }
              return;
            }
            if (payload case {
              'type': 'stt.error',
              'code': final String code,
              'message': final String message,
              'recoverable': final bool recoverable,
            }) {
              final event = SttSessionErrorEvent(
                code: code,
                message: message,
                recoverable: recoverable,
              );
              _eventsController.add(event);
              if (!ready.isCompleted) {
                ready.completeError(
                  SttSessionException(
                    code: code,
                    message: message,
                    recoverable: recoverable,
                  ),
                );
              }
              return;
            }
            if (payload case {
              'type': final String type,
              'segment_id': final String segmentId,
              'text': final String text,
              'language': final String language,
            }) {
              final kind = switch (type) {
                'transcript.interim' => SttTranscriptKind.interim,
                'transcript.final' => SttTranscriptKind.finalResult,
                _ => null,
              };
              if (kind != null) {
                _eventsController.add(
                  SttTranscriptEvent(
                    kind: kind,
                    segmentId: segmentId,
                    text: text,
                    language: language,
                  ),
                );
              }
            }
          }
        },
        onDone: () {
          if (attempt.isCancelled || !identical(_connectAttempt, attempt)) {
            return;
          }
          if (!ready.isCompleted) {
            ready.completeError(
              StateError('STT connection closed before readiness.'),
            );
          } else if (!closedEventSent) {
            closedEventSent = true;
            _eventsController.add(
              const SttSessionClosedEvent(unexpected: true),
            );
          }
          if (identical(_socket, socket)) {
            _socket = null;
          }
          _isReady = false;
        },
        onError: (Object error, StackTrace stackTrace) {
          if (attempt.isCancelled || !identical(_connectAttempt, attempt)) {
            return;
          }
          if (!ready.isCompleted) {
            ready.completeError(error, stackTrace);
          } else if (!closedEventSent) {
            closedEventSent = true;
            _eventsController.add(
              const SttSessionClosedEvent(unexpected: true),
            );
          }
          _isReady = false;
        },
      );
      socket.send(
        jsonEncode({
          'type': 'stt.start',
          'audio': {
            'encoding': 'pcm_s16le',
            'sample_rate_hz': 16000,
            'channels': 1,
          },
          'language': 'vi',
        }),
      );
      await Future.any<void>([
        ready.future.timeout(connectionTimeout),
        attempt.cancelled.then<void>(
          (_) => throw _connectionCancelledException,
        ),
      ]);
    } on TimeoutException {
      await disconnect();
      throw const SttSessionException(
        code: 'connection_timeout',
        message: 'The STT session timed out while connecting.',
        recoverable: true,
      );
    }
  }

  @override
  Future<void> sendAudio(Uint8List audio) async {
    final socket = _socket;
    if (!_isReady || socket == null) {
      throw const SttSessionException(
        code: 'session_not_ready',
        message: 'The STT session is not ready to receive audio.',
        recoverable: true,
      );
    }
    socket.send(audio);
  }

  @override
  Future<void> stop() async {
    _isReady = false;
    _socket?.send(jsonEncode({'type': 'stt.stop'}));
  }

  @override
  Future<void> disconnect() async {
    final attempt = _connectAttempt;
    _connectAttempt = null;
    _connectFuture = null;
    attempt?.cancel();
    await _closeSocket();
  }

  Future<void> _closeSocket() async {
    _isReady = false;
    await _subscription?.cancel();
    _subscription = null;
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/stt_session_id.dart';
import '../diagnostics/stt_transcript_trace.dart';
import '../translation/translation_domain.dart';
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
    this.streamId,
  });

  final SttTranscriptKind kind;
  final String segmentId;
  final String text;
  final String language;
  final String? streamId;
}

class SttTranslationEvent extends SttSessionEvent {
  const SttTranslationEvent(this.translation);

  final TranslationEvent translation;
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

  Future<void> connect({
    SttSessionStartOptions options = const SttSessionStartOptions(),
  });

  Future<void> sendAudio(Uint8List audio);

  Future<void> stop();

  Future<void> disconnect();
}

class SttSessionStartOptions {
  const SttSessionStartOptions({this.translationTarget});

  final TranslationTargetLanguage? translationTarget;
}

class SttWebSocketService implements SttSessionTransport {
  SttWebSocketService({
    required this.baseUrl,
    required SocketConnector connector,
    String? sessionId,
    this.connectionTimeout = const Duration(seconds: 5),
    this.stopTimeout = const Duration(seconds: 8),
    this.transcriptTrace = const DisabledSttTranscriptTrace(),
  }) : sessionId = normalizeSttSessionId(sessionId),
       _connector = connector;

  final String baseUrl;
  final String? sessionId;
  final SocketConnector _connector;
  final Duration connectionTimeout;
  final Duration stopTimeout;
  final SttTranscriptTrace transcriptTrace;
  final StreamController<SttSessionEvent> _eventsController =
      StreamController<SttSessionEvent>.broadcast();

  SocketConnection? _socket;
  StreamSubscription<dynamic>? _subscription;
  Future<void>? _connectFuture;
  _SttConnectAttempt? _connectAttempt;
  bool _isReady = false;
  bool _isStopping = false;
  Completer<void>? _stopCompleter;
  Future<void>? _stopFuture;
  int _transcriptReceiveSequence = 0;

  @override
  Stream<SttSessionEvent> get events => _eventsController.stream;

  @override
  Future<void> connect({
    SttSessionStartOptions options = const SttSessionStartOptions(),
  }) {
    final activeConnect = _connectFuture;
    if (activeConnect != null) {
      return activeConnect;
    }

    final attempt = _SttConnectAttempt();
    _connectAttempt = attempt;
    late final Future<void> sharedConnect;
    sharedConnect = _connect(attempt, options).whenComplete(() {
      if (identical(_connectFuture, sharedConnect)) {
        _connectFuture = null;
      }
    });
    _connectFuture = sharedConnect;
    return sharedConnect;
  }

  Future<void> _connect(
    _SttConnectAttempt attempt,
    SttSessionStartOptions options,
  ) async {
    try {
      _isReady = false;
      _isStopping = false;
      _completeStopWaiter();
      _transcriptReceiveSequence = 0;
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
              _completeStopWaiter();
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
            if (payload['type'] is String &&
                (payload['type'] as String).startsWith('translation.')) {
              final translation = parseTranslationEvent(payload);
              if (translation != null) {
                _eventsController.add(SttTranslationEvent(translation));
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
                _transcriptReceiveSequence++;
                transcriptTrace.websocketTranscriptReceived(
                  sequence: _transcriptReceiveSequence,
                  segmentId: segmentId,
                  kind: kind == SttTranscriptKind.interim ? 'interim' : 'final',
                  text: text,
                  language: language,
                );
                _eventsController.add(
                  SttTranscriptEvent(
                    kind: kind,
                    segmentId: segmentId,
                    text: text,
                    language: language,
                    streamId: switch (payload['stream_id']) {
                      final String value when value.trim().isNotEmpty => value,
                      _ => null,
                    },
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
          } else if (!closedEventSent && !_isStopping) {
            closedEventSent = true;
            _eventsController.add(
              const SttSessionClosedEvent(unexpected: true),
            );
          }
          _completeStopWaiter();
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
          } else if (!closedEventSent && !_isStopping) {
            closedEventSent = true;
            _eventsController.add(
              const SttSessionClosedEvent(unexpected: true),
            );
          }
          _completeStopWaiter();
          _isReady = false;
        },
      );
      socket.send(
        jsonEncode({
          'type': 'stt.start',
          if (sessionId != null) 'session_id': sessionId,
          'audio': {
            'encoding': 'pcm_s16le',
            'sample_rate_hz': 16000,
            'channels': 1,
          },
          'language': 'vi',
          if (options.translationTarget != null)
            'translation': {'target_language': options.translationTarget!.code},
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
    final activeStop = _stopFuture;
    if (activeStop != null) {
      return activeStop;
    }
    _isReady = false;
    final socket = _socket;
    if (socket == null) {
      return;
    }
    _isStopping = true;
    final completer = Completer<void>();
    _stopCompleter = completer;
    socket.send(jsonEncode({'type': 'stt.stop'}));
    late final Future<void> sharedStop;
    sharedStop = completer.future
        .timeout(stopTimeout, onTimeout: _completeStopWaiter)
        .whenComplete(() {
          if (identical(_stopFuture, sharedStop)) {
            _stopFuture = null;
          }
        });
    _stopFuture = sharedStop;
    return sharedStop;
  }

  @override
  Future<void> disconnect() async {
    final attempt = _connectAttempt;
    _connectAttempt = null;
    _connectFuture = null;
    attempt?.cancel();
    _completeStopWaiter();
    _isStopping = false;
    await _closeSocket();
  }

  void _completeStopWaiter() {
    final completer = _stopCompleter;
    _stopCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
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

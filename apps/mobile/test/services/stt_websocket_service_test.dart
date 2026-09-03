import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_live_translator_mobile/diagnostics/stt_transcript_trace.dart';
import 'package:ai_live_translator_mobile/services/realtime_websocket_service.dart';
import 'package:ai_live_translator_mobile/services/stt_websocket_service.dart';
import 'package:ai_live_translator_mobile/translation/translation_domain.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeSttSocketConnection implements SocketConnection {
  final StreamController<dynamic> controller = StreamController<dynamic>();
  final List<dynamic> sentMessages = [];
  bool closed = false;

  @override
  Stream<dynamic> get stream => controller.stream;

  @override
  void send(dynamic data) {
    sentMessages.add(data);
  }

  @override
  Future<void> close() async {
    if (closed) {
      return;
    }
    closed = true;
    await controller.close();
  }
}

class CapturingServiceTranscriptTraceSink
    implements SttTranscriptTraceJsonlSink {
  final List<String> lines = [];

  @override
  void writeLine(String line) => lines.add(line);
}

Future<void> expectAudioToBeRejectedWhenNotReady(
  SttSessionTransport transport,
) {
  return expectLater(
    transport.sendAudio(Uint8List(0)),
    throwsA(
      isA<SttSessionException>()
          .having((error) => error.code, 'code', 'session_not_ready')
          .having((error) => error.recoverable, 'recoverable', isTrue),
    ),
  );
}

Map<String, Object?> configured() => {
  'type': 'translation.configured',
  'stream_id': 'stream_A',
  'source_language': 'vi',
  'target_language': 'en',
};

Map<String, Object?> pending() => {
  'type': 'translation.pending',
  'stream_id': 'stream_A',
  'utterance_id': 'utt_000001',
  'source_segment_ids': ['seg_1'],
  'source_text': 'Xin chao.',
  'source_language': 'vi',
  'target_language': 'en',
};

Map<String, Object?> finalEvent() => {
  ...pending(),
  'type': 'translation.final',
  'translated_text': 'Hello.',
};

Map<String, Object?> utteranceError() => {
  ...pending(),
  'type': 'translation.error',
  'scope': 'utterance',
  'code': 'provider_error',
  'message': 'Unavailable.',
};

void main() {
  test('connect opens /ws/stt and waits for normalized readiness', () async {
    Uri? connectedUri;
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async {
        connectedUri = uri;
        return socket;
      },
      sessionId: null,
    );
    var connected = false;

    final connectFuture = service.connect().then((_) => connected = true);
    await Future<void>.delayed(Duration.zero);

    expect(connectedUri, Uri.parse('ws://192.168.1.220:8000/ws/stt'));
    expect(connected, isFalse);
    expect(jsonDecode(socket.sentMessages.single as String), {
      'type': 'stt.start',
      'audio': {
        'encoding': 'pcm_s16le',
        'sample_rate_hz': 16000,
        'channels': 1,
      },
      'language': 'vi',
    });

    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;

    expect(connected, isTrue);

    await service.disconnect();
  });

  test('connect includes a valid session ID in stt.start', () async {
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
      sessionId: 'demo-001',
    );

    final connectFuture = service.connect();
    await Future<void>.delayed(Duration.zero);

    expect(jsonDecode(socket.sentMessages.single as String), {
      'type': 'stt.start',
      'session_id': 'demo-001',
      'audio': {
        'encoding': 'pcm_s16le',
        'sample_rate_hz': 16000,
        'channels': 1,
      },
      'language': 'vi',
    });

    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;
    await service.disconnect();
  });

  test('connect omits a blank session ID from stt.start', () async {
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
      sessionId: '  ',
    );

    final connectFuture = service.connect();
    await Future<void>.delayed(Duration.zero);

    final startMessage =
        jsonDecode(socket.sentMessages.single as String)
            as Map<String, dynamic>;
    expect(startMessage, isNot(contains('session_id')));

    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;
    await service.disconnect();
  });

  test('invalid session IDs fail before opening a socket', () {
    var connectorCalled = false;

    expect(
      () => SttWebSocketService(
        baseUrl: 'ws://192.168.1.220:8000',
        connector: (uri) async {
          connectorCalled = true;
          return FakeSttSocketConnection();
        },
        sessionId: 'bad session',
      ),
      throwsFormatException,
    );
    expect(connectorCalled, isFalse);
  });

  test('sends raw binary audio only after the STT session is ready', () async {
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );
    final audio = Uint8List.fromList([0, 1, 127, 255]);

    final connectFuture = service.connect();
    await Future<void>.delayed(Duration.zero);

    await expectLater(
      service.sendAudio(audio),
      throwsA(
        isA<SttSessionException>()
            .having((error) => error.code, 'code', 'session_not_ready')
            .having((error) => error.recoverable, 'recoverable', isTrue),
      ),
    );
    expect(socket.sentMessages, hasLength(1));

    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;

    await service.sendAudio(audio);

    expect(socket.sentMessages, hasLength(2));
    expect(socket.sentMessages.last, same(audio));
    expect(socket.sentMessages.last, isA<Uint8List>());

    await service.disconnect();
  });

  test('stop resets readiness and rejects later audio', () async {
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );
    final connectFuture = service.connect();
    await Future<void>.delayed(Duration.zero);
    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;

    final stopFuture = service.stop();
    await Future<void>.delayed(Duration.zero);
    socket.controller.add(jsonEncode({'type': 'stt.closed'}));
    await stopFuture;

    await expectAudioToBeRejectedWhenNotReady(service);
    expect(socket.sentMessages, hasLength(2));

    await service.disconnect();
  });

  test('translation-enabled connect includes selected target', () async {
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );

    final connectFuture = service.connect(
      options: const SttSessionStartOptions(
        translationTarget: TranslationTargetLanguage.english,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(jsonDecode(socket.sentMessages.single as String), {
      'type': 'stt.start',
      'audio': {
        'encoding': 'pcm_s16le',
        'sample_rate_hz': 16000,
        'channels': 1,
      },
      'language': 'vi',
      'translation': {'target_language': 'en'},
    });

    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;
    await service.disconnect();
  });

  test('normalized Translation events reach typed consumers', () async {
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );
    final received = <TranslationEvent>[];
    final subscription = service.events
        .where((event) => event is SttTranslationEvent)
        .cast<SttTranslationEvent>()
        .listen((event) => received.add(event.translation));
    final connectFuture = service.connect();
    await Future<void>.delayed(Duration.zero);
    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;

    for (final payload in [
      configured(),
      pending(),
      finalEvent(),
      utteranceError(),
      {
        'type': 'translation.error',
        'scope': 'session',
        'stream_id': 'stream_A',
        'source_language': 'vi',
        'target_language': 'en',
        'code': 'provider_unavailable',
        'message': 'Unavailable.',
      },
    ]) {
      socket.controller.add(jsonEncode(payload));
    }
    await Future<void>.delayed(Duration.zero);

    expect(received, [
      isA<TranslationConfiguredEvent>(),
      isA<TranslationPendingEvent>(),
      isA<TranslationFinalEvent>(),
      isA<TranslationUtteranceErrorEvent>(),
      isA<TranslationSessionErrorEvent>(),
    ]);

    await subscription.cancel();
    await service.disconnect();
  });

  test(
    'malformed Translation event is ignored without closing transport',
    () async {
      final socket = FakeSttSocketConnection();
      final service = SttWebSocketService(
        baseUrl: 'ws://192.168.1.220:8000',
        connector: (uri) async => socket,
      );
      final events = <SttSessionEvent>[];
      final subscription = service.events.listen(events.add);
      final connectFuture = service.connect();
      await Future<void>.delayed(Duration.zero);
      socket.controller.add(jsonEncode({'type': 'stt.ready'}));
      await connectFuture;

      socket.controller.add(jsonEncode({...pending(), 'source_text': ''}));
      socket.controller.add(
        jsonEncode({
          'type': 'transcript.final',
          'stream_id': 'stream_A',
          'segment_id': 'seg_3',
          'text': 'Speech continues.',
          'language': 'vi',
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events.whereType<SttTranslationEvent>(), isEmpty);
      expect(events.whereType<SttSessionErrorEvent>(), isEmpty);
      expect(
        events.whereType<SttTranscriptEvent>().single.streamId,
        'stream_A',
      );
      expect(socket.closed, isFalse);

      await subscription.cancel();
      await service.disconnect();
    },
  );

  test('stop waits for trailing events and normalized stt.closed', () async {
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );
    final trailing = <SttSessionEvent>[];
    final subscription = service.events.listen(trailing.add);
    final connectFuture = service.connect();
    await Future<void>.delayed(Duration.zero);
    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;

    var stopped = false;
    final stopFuture = service.stop().then((_) => stopped = true);
    await Future<void>.delayed(Duration.zero);
    expect(stopped, isFalse);
    expect(socket.closed, isFalse);
    expect(jsonDecode(socket.sentMessages.last as String), {
      'type': 'stt.stop',
    });

    socket.controller.add(
      jsonEncode({
        'type': 'transcript.final',
        'stream_id': 'stream_A',
        'segment_id': 'seg_tail',
        'text': 'Tail source.',
        'language': 'vi',
      }),
    );
    socket.controller.add(jsonEncode(finalEvent()));
    socket.controller.add(jsonEncode({'type': 'stt.closed'}));
    await stopFuture;
    expect(stopped, isTrue);
    expect(trailing.whereType<SttTranscriptEvent>(), hasLength(1));
    expect(trailing.whereType<SttTranslationEvent>(), hasLength(1));
    expect(socket.closed, isFalse);

    await subscription.cancel();
    await service.disconnect();
  });

  test('stop has a bounded local timeout', () async {
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
      stopTimeout: const Duration(milliseconds: 20),
    );
    final connectFuture = service.connect();
    await Future<void>.delayed(Duration.zero);
    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;

    await service.stop().timeout(const Duration(seconds: 1));

    expect(socket.closed, isFalse);
    await service.disconnect();
  });

  test(
    'disconnect resets readiness before a new connection is ready',
    () async {
      final firstSocket = FakeSttSocketConnection();
      final secondSocket = FakeSttSocketConnection();
      final sockets = <FakeSttSocketConnection>[firstSocket, secondSocket];
      final service = SttWebSocketService(
        baseUrl: 'ws://192.168.1.220:8000',
        connector: (uri) async => sockets.removeAt(0),
      );
      final firstConnect = service.connect();
      await Future<void>.delayed(Duration.zero);
      firstSocket.controller.add(jsonEncode({'type': 'stt.ready'}));
      await firstConnect;

      await service.disconnect();
      final secondConnect = service.connect();
      await Future<void>.delayed(Duration.zero);

      await expectAudioToBeRejectedWhenNotReady(service);
      expect(secondSocket.sentMessages, hasLength(1));

      secondSocket.controller.add(jsonEncode({'type': 'stt.ready'}));
      await secondConnect;
      await service.disconnect();
    },
  );

  test(
    'normalized stt.closed resets readiness and rejects later audio',
    () async {
      final socket = FakeSttSocketConnection();
      final service = SttWebSocketService(
        baseUrl: 'ws://192.168.1.220:8000',
        connector: (uri) async => socket,
      );
      final closed = service.events
          .where((event) => event is SttSessionClosedEvent)
          .cast<SttSessionClosedEvent>()
          .first;
      final connectFuture = service.connect();
      await Future<void>.delayed(Duration.zero);
      socket.controller.add(jsonEncode({'type': 'stt.ready'}));
      await connectFuture;

      socket.controller.add(jsonEncode({'type': 'stt.closed'}));
      await closed;

      await expectAudioToBeRejectedWhenNotReady(service);
      await service.disconnect();
    },
  );

  test(
    'stream completion resets readiness before a new connection is ready',
    () async {
      final firstSocket = FakeSttSocketConnection();
      final secondSocket = FakeSttSocketConnection();
      final sockets = <FakeSttSocketConnection>[firstSocket, secondSocket];
      final service = SttWebSocketService(
        baseUrl: 'ws://192.168.1.220:8000',
        connector: (uri) async => sockets.removeAt(0),
      );
      final closed = service.events
          .where((event) => event is SttSessionClosedEvent)
          .cast<SttSessionClosedEvent>()
          .first;
      final firstConnect = service.connect();
      await Future<void>.delayed(Duration.zero);
      firstSocket.controller.add(jsonEncode({'type': 'stt.ready'}));
      await firstConnect;

      await firstSocket.controller.close();
      await closed;
      final secondConnect = service.connect();
      await Future<void>.delayed(Duration.zero);

      await expectAudioToBeRejectedWhenNotReady(service);
      expect(secondSocket.sentMessages, hasLength(1));

      secondSocket.controller.add(jsonEncode({'type': 'stt.ready'}));
      await secondConnect;
      await service.disconnect();
    },
  );

  test('stream errors reset readiness and reject later audio', () async {
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );
    final closed = service.events
        .where((event) => event is SttSessionClosedEvent)
        .cast<SttSessionClosedEvent>()
        .first;
    final connectFuture = service.connect();
    await Future<void>.delayed(Duration.zero);
    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;

    socket.controller.addError(StateError('socket stream error'));
    await closed;

    await expectAudioToBeRejectedWhenNotReady(service);
    await service.disconnect();
  });

  test(
    'provider unavailable before readiness fails with normalized error',
    () async {
      final socket = FakeSttSocketConnection();
      final service = SttWebSocketService(
        baseUrl: 'ws://192.168.1.220:8000',
        connector: (uri) async => socket,
      );

      final connectFuture = service.connect().timeout(
        const Duration(milliseconds: 100),
      );
      await Future<void>.delayed(Duration.zero);
      socket.controller.add(
        jsonEncode({
          'type': 'stt.error',
          'code': 'provider_unavailable',
          'message': 'STT provider is unavailable.',
          'recoverable': false,
        }),
      );

      await expectLater(
        connectFuture,
        throwsA(
          isA<SttSessionException>()
              .having((error) => error.code, 'code', 'provider_unavailable')
              .having(
                (error) => error.message,
                'message',
                'STT provider is unavailable.',
              )
              .having((error) => error.recoverable, 'recoverable', isFalse),
        ),
      );

      await service.disconnect();
    },
  );

  test('connect times out instead of waiting indefinitely', () async {
    final pendingSocket = Completer<SocketConnection>();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) => pendingSocket.future,
      connectionTimeout: const Duration(milliseconds: 10),
    );

    await expectLater(
      service.connect(),
      throwsA(
        isA<SttSessionException>()
            .having((error) => error.code, 'code', 'connection_timeout')
            .having(
              (error) => error.message,
              'message',
              'The STT session timed out while connecting.',
            ),
      ),
    );
  });

  test('concurrent connect calls share one handshake', () async {
    final socket = FakeSttSocketConnection();
    var connectorCalls = 0;
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async {
        connectorCalls++;
        return socket;
      },
    );

    final firstConnect = service.connect();
    final secondConnect = service.connect();
    final bothConnections = Future.wait([firstConnect, secondConnect]);
    await Future<void>.delayed(Duration.zero);

    expect(connectorCalls, 1);

    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await bothConnections;
    await service.disconnect();
  });

  test('disconnect cancels pending readiness before a fresh connect', () async {
    final firstSocket = FakeSttSocketConnection();
    final secondSocket = FakeSttSocketConnection();
    final sockets = <FakeSttSocketConnection>[firstSocket, secondSocket];
    var connectorCalls = 0;
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async {
        connectorCalls++;
        return sockets.removeAt(0);
      },
      connectionTimeout: const Duration(milliseconds: 50),
    );

    final firstResult = service.connect().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    await Future<void>.delayed(Duration.zero);

    await service.disconnect();
    final secondResult = service.connect().then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    await Future<void>.delayed(Duration.zero);

    expect(connectorCalls, 2);
    expect(
      await firstResult,
      isA<SttSessionException>().having(
        (error) => error.code,
        'code',
        'connection_cancelled',
      ),
    );

    secondSocket.controller.add(jsonEncode({'type': 'stt.ready'}));
    expect(await secondResult, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 75));
    expect(secondSocket.closed, isFalse);

    await service.disconnect();
  });

  test('normalized transcript event is exposed to session consumers', () async {
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );
    final transcriptFuture = service.events
        .where((event) => event is SttTranscriptEvent)
        .cast<SttTranscriptEvent>()
        .first;
    final connectFuture = service.connect();
    await Future<void>.delayed(Duration.zero);
    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;

    socket.controller.add(
      jsonEncode({
        'type': 'transcript.final',
        'segment_id': 'segment-1',
        'text': 'Xin chao',
        'language': 'vi',
      }),
    );

    final transcript = await transcriptFuture.timeout(
      const Duration(milliseconds: 100),
    );
    expect(transcript.kind, SttTranscriptKind.finalResult);
    expect(transcript.segmentId, 'segment-1');
    expect(transcript.text, 'Xin chao');
    expect(transcript.language, 'vi');

    await service.disconnect();
  });

  test('received transcript trace preserves local receive order', () async {
    final socket = FakeSttSocketConnection();
    final sink = CapturingServiceTranscriptTraceSink();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
      transcriptTrace: createSttTranscriptTrace(enabled: true, sink: sink),
    );
    final transcriptsFuture = service.events
        .where((event) => event is SttTranscriptEvent)
        .take(2)
        .toList();
    final connectFuture = service.connect();
    await Future<void>.delayed(Duration.zero);
    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;

    socket.controller.add(
      jsonEncode({
        'type': 'transcript.interim',
        'segment_id': 'segment-a',
        'text': 'Xin',
        'language': 'vi',
      }),
    );
    socket.controller.add(
      jsonEncode({
        'type': 'transcript.final',
        'segment_id': 'segment-a',
        'text': 'Xin chao.',
        'language': 'vi',
      }),
    );
    await transcriptsFuture;

    final traced = sink.lines
        .map(
          (line) =>
              jsonDecode(line.substring(sttTranscriptTraceLinePrefix.length))
                  as Map<String, Object?>,
        )
        .toList();
    expect(traced.map((event) => event['receive_sequence']), [1, 2]);
    expect(traced.map((event) => event['kind']), ['interim', 'final']);
    expect(traced.last['text'], 'Xin chao.');

    await service.disconnect();
  });

  test('remote close after readiness emits unexpected closed event', () async {
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );
    final closedFuture = service.events
        .where((event) => event is SttSessionClosedEvent)
        .cast<SttSessionClosedEvent>()
        .first;
    final connectFuture = service.connect();
    await Future<void>.delayed(Duration.zero);
    socket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await connectFuture;

    await socket.controller.close();

    final closed = await closedFuture.timeout(
      const Duration(milliseconds: 100),
    );
    expect(closed.unexpected, isTrue);
  });

  test('normalized stt.closed is not reported as transport loss', () async {
    final socket = FakeSttSocketConnection();
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => socket,
    );
    final closedFuture = service.events
        .where((event) => event is SttSessionClosedEvent)
        .cast<SttSessionClosedEvent>()
        .first;
    final connectFuture = service.connect();
    await Future<void>.delayed(Duration.zero);
    socket.controller.add(
      jsonEncode({
        'type': 'stt.error',
        'code': 'provider_unavailable',
        'message': 'STT provider is unavailable.',
        'recoverable': false,
      }),
    );
    await expectLater(connectFuture, throwsA(isA<SttSessionException>()));

    socket.controller.add(jsonEncode({'type': 'stt.closed'}));

    final closed = await closedFuture.timeout(
      const Duration(milliseconds: 100),
    );
    expect(closed.unexpected, isFalse);
    await service.disconnect();
  });

  test('new connect cleans up stale socket after startup failure', () async {
    final firstSocket = FakeSttSocketConnection();
    final secondSocket = FakeSttSocketConnection();
    final sockets = <FakeSttSocketConnection>[firstSocket, secondSocket];
    final service = SttWebSocketService(
      baseUrl: 'ws://192.168.1.220:8000',
      connector: (uri) async => sockets.removeAt(0),
    );
    final firstConnect = service.connect();
    await Future<void>.delayed(Duration.zero);
    firstSocket.controller.add(
      jsonEncode({
        'type': 'stt.error',
        'code': 'provider_unavailable',
        'message': 'STT provider is unavailable.',
        'recoverable': false,
      }),
    );
    await expectLater(firstConnect, throwsA(isA<SttSessionException>()));

    final secondConnect = service.connect();
    await Future<void>.delayed(Duration.zero);

    expect(firstSocket.closed, isTrue);
    secondSocket.controller.add(jsonEncode({'type': 'stt.ready'}));
    await secondConnect;
    await service.disconnect();
  });

  test(
    'malformed server message fails safely without exposing payload',
    () async {
      final socket = FakeSttSocketConnection();
      final service = SttWebSocketService(
        baseUrl: 'ws://192.168.1.220:8000',
        connector: (uri) async => socket,
      );
      final connectFuture = service.connect().timeout(
        const Duration(milliseconds: 100),
      );
      await Future<void>.delayed(Duration.zero);

      socket.controller.add('{not valid json');

      await expectLater(
        connectFuture,
        throwsA(
          isA<SttSessionException>()
              .having((error) => error.code, 'code', 'invalid_server_message')
              .having(
                (error) => error.message,
                'message',
                'Received an invalid STT server message.',
              ),
        ),
      );
      await service.disconnect();
    },
  );
}
